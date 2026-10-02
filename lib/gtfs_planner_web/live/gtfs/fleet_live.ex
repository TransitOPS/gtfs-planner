defmodule GtfsPlannerWeb.Gtfs.FleetLive do
  @moduledoc """
  LiveView for the organization's fleet: the type-by-garage count matrix, the
  URL-backed filters and the bounded vehicle list.

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

  The matrix and the totals count the whole tenant fleet, not the filtered subset:
  `Operations.fleet_summary/1` buckets by garage × type and the page derives the
  matrix, the total and the number of vehicles needing a garage or type from those
  buckets. Rows stream through `#vehicles-table`, so about two thousand vehicles
  do not balloon the socket.

  A collapsed `#vehicle-types` disclosure holds the types table and its add/edit
  drawer. A type is organization-wide and ignores versions like a vehicle; its
  optional limit is edited as hours and stored as minutes by
  `Operations.VehicleType`, and deletion is refused while any vehicle, block
  attribute or route operating setting requires the type: the page reads
  `Operations.vehicle_type_in_use_counts/2` before opening the confirmation and
  `Operations.delete_vehicle_type/3` still attempts the write, naming the same
  counts when a reference appears in between.

  `#vehicle-drawer` edits one vehicle and creates a numbered group. Adding uses
  a One vehicle / Numbered group mode switch; the numbered-group `#range-preview`
  applies the same padding rule as `Operations.create_vehicle_range/3` so
  `0098`–`0102` reads as five padded IDs, but the context remains authoritative:
  the preview is feedback and a refused submit keeps the mode and the entries.

  `#vehicles-table` rows carry a checkbox and its header cell carries the
  select-all-filtered control. The selection is a `MapSet` of vehicle UUIDs and
  holds only what the operator or the filtered rows put there: select-all takes
  the ids of the rows currently streamed, and a filter change clears the set. The
  `#bulk-bar` appears while it is non-empty; `#bulk-drawer` writes one assignment
  through `Operations.update_vehicles/4` (the blank “No type” or “No garage” prompt
  clears it) and bulk deletion confirms first, naming up to five vehicles.

  Event ids are passed to the context unchanged, so a crafted or stale id is
  accepted into the selection and refused by the context's ownership check
  instead of by a page-side guess: the write changes nothing, the selection is
  cleared and the list reloads with “Some vehicles are no longer available.”

  "Import vehicles" opens the shared `tods_import_drawer/1`: the chosen
  file is parsed by `Tods` and previewed through `Operations.preview_tods_import/2`,
  and only the reviewed plan may be applied. The review describes exactly one
  upload, so closing the drawer, cancelling the upload or choosing another file
  discards it rather than leaving a plan that no longer matches the screen. An
  import never changes a vehicle's type or garage.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents,
    only: [in_use_message: 2, in_use_summary: 1, tods_import_drawer: 1, tods_review_current?: 2]

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      back_link: 1,
      drawer_footer: 1,
      drawer_scroll: 1,
      first_use: 1,
      message: 1,
      scope_line: 1
    ]

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias Plug.Conn.Query

  @vehicle_type_form_id "vehicle-type-form"
  @vehicle_type_form_error_id "vehicle-type-form-error"
  @vehicle_form_id "vehicle-form"
  @vehicle_form_error_id "vehicle-form-error"
  @range_form_id "vehicle-range-form"
  @bulk_form_id "bulk-form"

  # The delete confirmation names the selected vehicles; beyond this it reports
  # how many more the request covers.
  @bulk_name_limit 5

  # Mirrors the two bounds `Operations.create_vehicle_range/3` enforces before it
  # allocates anything; the preview only reports them and never relaxes them.
  @range_limit 200
  @max_vehicle_id_length 255

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @permission_error "You no longer have permission to edit the fleet. " <>
                      "Ask an organization administrator to restore your access."

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
     |> assign(:matrix_columns, [])
     |> assign(:vehicles_empty?, true)
     |> assign(:vehicle_types_empty?, true)
     |> assign(:type_drawer_open, false)
     |> assign(:type_entity, nil)
     |> assign(:type_counts, nil)
     |> assign(:type_form, vehicle_type_form(%VehicleType{}, %{}))
     |> assign(:type_drawer_title, "Add vehicle type")
     |> assign(:type_drawer_return_focus_id, nil)
     |> assign(:type_notice, nil)
     |> assign(:type_delete_target, nil)
     |> assign(:type_in_use, nil)
     |> assign(:vehicle_drawer_open, false)
     |> assign(:vehicle_mode, :single)
     |> assign(:vehicle_entity, nil)
     |> assign(:vehicle_form, vehicle_form(%Vehicle{}, %{}))
     |> assign(:range_form, vehicle_range_form(%{}))
     |> assign(:range_preview, range_preview_message("", ""))
     |> assign(:vehicle_drawer_title, "Add vehicles")
     |> assign(:vehicle_drawer_return_focus_id, nil)
     |> assign(:vehicle_notice, nil)
     |> assign(:vehicle_error, nil)
     |> assign(:vehicle_type_choices, [])
     |> assign(:garage_choices, [])
     |> assign(:selected_ids, MapSet.new())
     |> assign(:filtered_vehicles, [])
     |> assign(:bulk_field, nil)
     |> assign(:bulk_form, bulk_form(%{}))
     |> assign(:bulk_drawer_open, false)
     |> assign(:bulk_drawer_return_focus_id, nil)
     |> assign(:bulk_error, nil)
     |> assign(:bulk_delete, nil)
     |> assign(:tods_import_open, false)
     |> assign(:tods_import_filename, nil)
     |> assign(:tods_import_parsed, nil)
     |> assign(:tods_import_preview, nil)
     |> assign(:tods_import_parse_error, nil)
     |> assign(:tods_import_stale?, false)
     |> assign(:tods_import_return_focus_id, nil)
     |> allow_upload(:tods_file,
       accept: ~w(.txt .csv),
       max_entries: 1,
       max_file_size: Tods.max_import_bytes(),
       auto_upload: true,
       progress: &handle_tods_file_progress/3
     )
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

  # --- TODS import -----------------------------------------------------------

  @impl true
  def handle_event("open_tods_import", params, socket) do
    {:noreply,
     socket
     |> reset_tods_import_review()
     |> assign(:tods_import_return_focus_id, params["opener_id"] || "import-tods")
     |> assign(:tods_import_open, true)}
  end

  @impl true
  def handle_event("close_tods_import_drawer", _params, socket) do
    {:noreply,
     socket
     |> discard_tods_upload()
     |> reset_tods_import_review()
     |> assign(:tods_import_open, false)}
  end

  @impl true
  def handle_event("cancel_tods_upload", %{"ref" => ref}, socket) do
    {:noreply, socket |> cancel_upload(:tods_file, ref) |> reset_tods_import_review()}
  end

  def handle_event("cancel_tods_upload", _params, socket), do: {:noreply, socket}

  # LiveView routes the file input's change through the drawer's form, so the form
  # declares a change event; the drawer holds no other form state to validate.
  @impl true
  def handle_event("validate_tods_import", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("apply_tods_import", _params, socket) do
    parsed = socket.assigns.tods_import_parsed
    preview = socket.assigns.tods_import_preview

    if is_map(parsed) and tods_review_current?(preview, socket.assigns.uploads.tods_file) do
      apply_reviewed_tods_import(socket, parsed, preview)
    else
      # A crafted or stale event finds no reviewed file to apply.
      {:noreply, socket}
    end
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

    result =
      case socket.assigns.type_entity do
        nil ->
          Operations.create_vehicle_type(organization_id, actor(socket), params)

        vehicle_type ->
          Operations.update_vehicle_type(organization_id, actor(socket), vehicle_type.id, params)
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

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:type_form, vehicle_type_form(vehicle_type_base(socket), params))
         |> put_flash(:error, @permission_error)}
    end
  end

  def handle_event("save_vehicle_type", _params, socket), do: {:noreply, socket}

  # --- vehicle type deletion -------------------------------------------------

  @impl true
  def handle_event("delete_vehicle_type", %{"type_id" => id}, socket) when is_binary(id) do
    case load_vehicle_type(socket, id) do
      nil ->
        {:noreply, socket}

      vehicle_type ->
        counts =
          Operations.vehicle_type_in_use_counts(
            socket.assigns.current_organization.id,
            vehicle_type.id
          )

        if Operations.in_use?(counts) do
          {:noreply, show_type_in_use(socket, vehicle_type, counts)}
        else
          {:noreply, assign(socket, :type_delete_target, vehicle_type)}
        end
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

  # --- vehicle drawer --------------------------------------------------------

  @impl true
  def handle_event("open_vehicle", %{"vehicle_id" => id} = params, socket)
      when is_binary(id) and id != "" do
    case load_vehicle(socket, id) do
      nil ->
        {:noreply, socket}

      vehicle ->
        {:noreply, open_edit_vehicle(socket, vehicle, params["opener_id"])}
    end
  end

  def handle_event("open_vehicle", params, socket) do
    {:noreply, open_add_vehicle(socket, params["opener_id"])}
  end

  @impl true
  def handle_event("close_vehicle_drawer", _params, socket) do
    {:noreply, close_vehicle_drawer(socket)}
  end

  @impl true
  def handle_event("select_vehicle_mode", %{"vehicle_mode" => mode}, socket) do
    case vehicle_mode(mode) do
      nil -> {:noreply, socket}
      mode -> {:noreply, switch_vehicle_mode(socket, mode)}
    end
  end

  def handle_event("select_vehicle_mode", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate_vehicle", %{"vehicle" => params}, socket) do
    changeset =
      socket
      |> vehicle_base()
      |> Operations.change_vehicle(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :vehicle_form, to_form(changeset, as: :vehicle))}
  end

  def handle_event("validate_vehicle", _payload, socket), do: {:noreply, socket}

  # The preview is recomputed from the submitted entries, so the server owns the
  # padding rule and the browser never has to. Editing the range also clears a
  # previous refusal, which the operator is correcting.
  @impl true
  def handle_event("validate_vehicle_range", %{"range" => params}, socket) do
    {:noreply, socket |> assign_vehicle_range(params) |> assign(:vehicle_error, nil)}
  end

  def handle_event("validate_vehicle_range", _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_vehicle", %{"vehicle" => params}, socket) do
    organization_id = socket.assigns.current_organization.id
    actor = actor(socket)
    editing? = not is_nil(socket.assigns.vehicle_entity)

    result =
      case socket.assigns.vehicle_entity do
        nil -> Operations.create_vehicle(organization_id, actor, params)
        vehicle -> Operations.update_vehicle(organization_id, actor, vehicle.id, params)
      end

    case result do
      {:ok, vehicle} ->
        {:noreply,
         socket
         |> close_vehicle_drawer()
         |> load_fleet()
         |> assign(:vehicle_notice, vehicle_saved_notice(vehicle.vehicle_id, editing?))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:vehicle_form, to_form(changeset, as: :vehicle))
         |> push_event("focus_form_error", %{
           form_id: @vehicle_form_id,
           fallback_id: @vehicle_form_error_id
         })}

      {:error, :not_found} ->
        # The vehicle or one of its assignments disappeared before the save.
        {:noreply, socket |> close_vehicle_drawer() |> load_fleet()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(
           :vehicle_form,
           vehicle_form(socket.assigns.vehicle_entity || %Vehicle{}, params)
         )
         |> put_flash(:error, @permission_error)}
    end
  end

  def handle_event("save_vehicle", %{"range" => params}, socket) do
    organization_id = socket.assigns.current_organization.id
    actor = actor(socket)

    case Operations.create_vehicle_range(organization_id, actor, params) do
      {:ok, vehicles} ->
        {:noreply,
         socket
         |> close_vehicle_drawer()
         |> load_fleet()
         |> assign(:vehicle_notice, vehicles_added_notice(length(vehicles)))}

      # A rejected batch changes nothing, so the mode and the entries stay put.
      {:error, {:invalid_range, message}} ->
        {:noreply,
         socket
         |> assign_vehicle_range(params)
         |> assign(:vehicle_error, message)
         |> focus_vehicle_form_error()}

      {:error, {:ids_taken, ids}} ->
        {:noreply,
         socket
         |> assign_vehicle_range(params)
         |> assign(:vehicle_error, ids_taken_message(ids))
         |> focus_vehicle_form_error()}

      {:error, :not_found} ->
        {:noreply, socket |> close_vehicle_drawer() |> load_fleet()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign_vehicle_range(params)
         |> put_flash(:error, @permission_error)}
    end
  end

  def handle_event("save_vehicle", _params, socket), do: {:noreply, socket}

  # --- vehicle selection and bulk actions ------------------------------------

  # The event carries an id the page never validated, and that is deliberate: the
  # context re-validates every listed id and every target against the organization
  # before it writes, so crafted, foreign and stale ids fail closed there and the
  # page only reports the outcome. A row that leaves the current filter keeps its
  # selection until the operator changes filter, which is the event that clears it.
  @impl true
  def handle_event("toggle_vehicle_selection", %{"vehicle_id" => id}, socket)
      when is_binary(id) do
    {:noreply,
     socket
     |> assign(:selected_ids, toggle_selection(socket.assigns.selected_ids, id))
     |> restream_vehicles([id])}
  end

  def handle_event("toggle_vehicle_selection", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_all_filtered", _params, socket) do
    ids = Enum.map(socket.assigns.filtered_vehicles, & &1.id)

    {:noreply, socket |> assign(:selected_ids, MapSet.new(ids)) |> restream_vehicles(ids)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  @impl true
  def handle_event("open_bulk_drawer", %{"field" => field} = params, socket) do
    case bulk_field(field) do
      nil ->
        {:noreply, socket}

      field ->
        {:noreply,
         socket
         |> assign(:bulk_field, field)
         |> assign(:bulk_form, bulk_form(%{}))
         |> assign(:bulk_drawer_return_focus_id, params["opener_id"])
         |> assign(:bulk_error, nil)
         |> assign(:bulk_drawer_open, true)}
    end
  end

  def handle_event("open_bulk_drawer", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_bulk_drawer", _params, socket) do
    {:noreply, assign(socket, :bulk_drawer_open, false)}
  end

  @impl true
  def handle_event("save_bulk_assignment", %{"bulk" => params}, socket) do
    field = socket.assigns.bulk_field

    if is_nil(field) or empty_selection?(socket.assigns.selected_ids) do
      {:noreply, socket}
    else
      assignment = {field, bulk_target(params["value"])}

      case Operations.update_vehicles(
             socket.assigns.current_organization.id,
             actor(socket),
             MapSet.to_list(socket.assigns.selected_ids),
             assignment
           ) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:bulk_drawer_open, false)
           |> assign(:vehicle_notice, bulk_updated_notice(field, count))
           |> reset_selection()
           |> load_fleet()}

        {:error, :not_found} ->
          {:noreply, stale_selection(socket)}

        {:error, :forbidden} ->
          {:noreply,
           socket
           |> assign(:bulk_form, bulk_form(params))
           |> put_flash(:error, @permission_error)}
      end
    end
  end

  def handle_event("save_bulk_assignment", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete_selected_vehicles", _params, socket) do
    if empty_selection?(socket.assigns.selected_ids) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :bulk_delete, bulk_delete_summary(socket))}
    end
  end

  @impl true
  def handle_event("cancel_delete_selected_vehicles", _params, socket) do
    {:noreply, assign(socket, :bulk_delete, nil)}
  end

  @impl true
  def handle_event("confirm_delete_selected_vehicles", _params, socket) do
    socket = assign(socket, :bulk_delete, nil)
    ids = MapSet.to_list(socket.assigns.selected_ids)

    if empty_selection?(socket.assigns.selected_ids) do
      {:noreply, socket}
    else
      case Operations.delete_vehicles(
             socket.assigns.current_organization.id,
             actor(socket),
             ids
           ) do
        {:ok, count} ->
          {:noreply,
           socket
           |> assign(:vehicle_notice, "#{Wording.count_noun(count, "vehicle")} deleted.")
           |> reset_selection()
           |> load_fleet()}

        {:error, :not_found} ->
          {:noreply, stale_selection(socket)}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, @permission_error)}
      end
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
      <div id="fleet-page" class="ds-page">
        <.back_link id="settings-back" navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings"}>
          Settings
        </.back_link>

        <.header>
          Fleet
          <:subtitle>
            Your vehicles by type and garage. Block planning uses this list to check that a plan
            fits your fleet.
            <.scope_line id="fleet-scope" icon="hero-square-3-stack-3d">
              Applies to every service version at {@current_organization.name}. Switching versions
              doesn't change this list.
            </.scope_line>
          </:subtitle>
          <%!-- With no vehicles yet, the first-use panel carries both actions. --%>
          <:actions :if={!@vehicles_empty?}>
            <.button
              id="import-tods"
              variant="secondary"
              class="min-h-11"
              phx-click="open_tods_import"
              phx-value-opener_id="import-tods"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import vehicles
            </.button>
            <.button
              id="add-vehicles-header"
              class="min-h-11"
              phx-click="open_vehicle"
              phx-value-opener_id="add-vehicles-header"
            >
              <.icon name="hero-plus" class="size-4" /> Add vehicles
            </.button>
          </:actions>
        </.header>

        <div :if={@needs_assignment_count > 0} class="mb-6">
          <.message
            id="fleet-partial-warning"
            kind="warning"
            title={needs_assignment_title(@needs_assignment_count)}
          >
            Assign them so fleet checks can count them.
          </.message>
        </div>

        <section id="vehicle-types" aria-labelledby="types-title" class="mt-2">
          <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 pb-4">
            <div class="min-w-0 max-w-[62ch]">
              <h2
                id="types-title"
                class="font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong"
              >
                {if @vehicles_empty?, do: "Vehicle types", else: "Fleet by type and garage"}
              </h2>
              <p id="vehicle-types-help" class="mt-1.5 text-sm text-muted">
                {types_help(@vehicle_types_empty?, @vehicles_empty?)}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
              <.link
                id="manage-garages"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings/garages"}
                class="inline-flex min-h-11 items-center px-1 text-sm font-[650] text-action no-underline hover:text-action-hover hover:underline"
              >
                Manage garages
              </.link>
              <.button
                id="add-vehicle-type"
                variant="secondary"
                class="min-h-11"
                phx-click="open_vehicle_type"
                phx-value-opener_id="add-vehicle-type"
              >
                Add vehicle type
              </.button>
            </div>
          </div>

          <div :if={@type_notice} class="mb-4">
            <.message id="vehicle-type-notice" kind="success" title={@type_notice} />
          </div>

          <div
            id="vehicle-types-card"
            class="overflow-clip rounded-card border border-subtle bg-white"
          >
            <div :if={@vehicle_types_empty?} id="vehicle-types-empty" class="px-5 py-8 text-center">
              <h3 class="text-base font-bold text-strong">No vehicle types yet</h3>
              <p class="mx-auto mt-1.5 max-w-[52ch] text-sm text-muted">
                Group vehicles that do the same work, such as 35-foot buses and cutaways. Types let
                fleet checks count what you have.
              </p>
            </div>

            <.fleet_matrix
              :if={!@vehicle_types_empty?}
              rows={@streams.vehicle_types}
              columns={@matrix_columns}
              total={@total_count}
              vehicles_empty?={@vehicles_empty?}
            />
          </div>
        </section>

        <section id="vehicles-section" aria-labelledby="vehicles-title" class="mt-10">
          <h2
            id="vehicles-title"
            tabindex="-1"
            class={[
              "pb-4 font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong",
              @vehicles_empty? && "sr-only"
            ]}
          >
            Vehicles
          </h2>

          <div :if={@vehicle_notice || @bulk_error} class="mb-4 grid gap-3">
            <.message
              :if={@vehicle_notice}
              id="vehicle-notice"
              kind="success"
              title={@vehicle_notice}
            />
            <.message :if={@bulk_error} id="bulk-error" kind="warning" title="Selection refreshed">
              {@bulk_error}
            </.message>
          </div>

          <.first_use
            :if={@vehicles_empty?}
            id="vehicles-first-use-empty"
            title="Add your first vehicles"
            icon="hero-truck"
          >
            Enter one vehicle or add a numbered group, such as 2101 through 2115. Block planning
            uses them to check that a plan fits your fleet.
            <:action>
              <div class="flex flex-wrap justify-center gap-3">
                <.button
                  id="add-vehicles"
                  class="min-h-11"
                  phx-click="open_vehicle"
                  phx-value-opener_id="add-vehicles"
                >
                  <.icon name="hero-plus" class="size-4" /> Add vehicles
                </.button>
                <.button
                  id="import-tods"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="open_tods_import"
                  phx-value-opener_id="import-tods"
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Import vehicles
                </.button>
              </div>
            </:action>
          </.first_use>

          <div
            :if={!@vehicles_empty?}
            id="vehicles-card"
            class="overflow-clip rounded-card border border-subtle bg-white"
          >
            <.form
              for={@filters_form}
              id="vehicle-filters"
              role="search"
              phx-change="filter"
              class="flex flex-wrap items-end gap-3 border-b border-subtle px-4 py-4 md:px-5"
            >
              <div class="min-w-0 flex-1 basis-[220px] md:basis-[280px]">
                <.input
                  field={@filters_form[:q]}
                  type="search"
                  label="Find vehicle"
                  placeholder="Number, label or plate"
                  autocomplete="off"
                  phx-debounce="300"
                />
              </div>
              <div class="min-w-0 flex-1 basis-[150px] md:w-[210px] md:flex-none">
                <.input
                  field={@filters_form[:type]}
                  type="select"
                  label="Vehicle type"
                  prompt="All types"
                  options={@vehicle_type_options}
                />
              </div>
              <div class="min-w-0 flex-1 basis-[150px] md:w-[230px] md:flex-none">
                <.input
                  field={@filters_form[:garage]}
                  type="select"
                  label="Garage"
                  prompt="All garages"
                  options={@garage_options}
                />
              </div>
            </.form>

            <%!-- One row of fixed height: the result count, or the bulk actions once a
            vehicle is selected. Swapping them in place keeps the table from jumping. --%>
            <div
              :if={empty_selection?(@selected_ids)}
              class="flex min-h-[60px] flex-wrap items-center gap-x-3 gap-y-1 border-b border-subtle px-4 py-1 text-[13px] md:px-5"
            >
              <p id="vehicles-count" role="status" class="font-[650] tabular-nums text-strong">
                {count_summary(@filtered_count, @total_count, @filters_active?)}
              </p>
              <.button
                :if={@filters_active? && @filtered_count > 0}
                id="clear-filters"
                type="button"
                variant="quiet"
                class="ml-auto min-h-11 text-[13px] text-action hover:underline"
                phx-click="clear_filters"
              >
                Clear filters
              </.button>
            </div>

            <div
              :if={!empty_selection?(@selected_ids)}
              id="bulk-bar"
              role="status"
              class="flex min-h-[60px] flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle bg-selection px-4 py-2 md:px-5"
            >
              <strong id="bulk-bar-count" class="mr-auto text-sm tabular-nums text-strong">
                {Wording.count_noun(MapSet.size(@selected_ids), "vehicle")} selected
              </strong>
              <div class="flex flex-wrap items-center gap-2">
                <.button
                  id="bulk-set-type"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="open_bulk_drawer"
                  phx-value-field="type"
                  phx-value-opener_id="bulk-set-type"
                >
                  Set type
                </.button>
                <.button
                  id="bulk-set-garage"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="open_bulk_drawer"
                  phx-value-field="garage"
                  phx-value-opener_id="bulk-set-garage"
                >
                  Set garage
                </.button>
                <.button
                  id="bulk-delete"
                  variant="quiet"
                  class="min-h-11 border border-control bg-white text-error-fg hover:bg-error-bg"
                  phx-click="delete_selected_vehicles"
                >
                  Delete vehicles
                </.button>
                <.button
                  id="bulk-clear-selection"
                  variant="quiet"
                  class="min-h-11 text-action hover:underline"
                  phx-click="clear_selection"
                >
                  Clear selection
                </.button>
              </div>
            </div>

            <.vehicles_table
              :if={@filtered_count > 0}
              rows={@streams.vehicles}
              selected_ids={@selected_ids}
              all_selected?={all_filtered_selected?(@selected_ids, @filtered_vehicles)}
              count={@filtered_count}
            />

            <div
              :if={@filtered_count == 0}
              id="vehicles-filtered-empty"
              class="px-5 py-12 text-center"
            >
              <h3 class="text-base font-bold text-strong">No vehicles match</h3>
              <p class="mx-auto mt-1.5 max-w-[46ch] text-sm text-muted">
                Check the number, label or plate, or clear the filters to see all {@total_count} vehicles.
              </p>
              <.button
                id="clear-filters-empty"
                variant="secondary"
                class="mt-5 min-h-11"
                phx-click="clear_filters"
              >
                Clear filters
              </.button>
            </div>
          </div>
        </section>

        <.tods_import_drawer
          open={@tods_import_open}
          kind={:vehicles}
          upload={@uploads.tods_file}
          preview={@tods_import_preview}
          filename={@tods_import_filename}
          parse_error={@tods_import_parse_error}
          stale?={@tods_import_stale?}
          return_focus_id={@tods_import_return_focus_id}
        />

        <.vehicle_type_drawer
          open={@type_drawer_open}
          title={@type_drawer_title}
          entity={@type_entity}
          counts={@type_counts}
          form={@type_form}
          return_focus_id={@type_drawer_return_focus_id}
        />

        <.vehicle_drawer
          open={@vehicle_drawer_open}
          title={@vehicle_drawer_title}
          mode={@vehicle_mode}
          entity={@vehicle_entity}
          form={@vehicle_form}
          range_form={@range_form}
          type_options={@vehicle_type_choices}
          garage_options={@garage_choices}
          range_preview={@range_preview}
          error={@vehicle_error}
          return_focus_id={@vehicle_drawer_return_focus_id}
        />

        <.bulk_drawer
          open={@bulk_drawer_open}
          field={@bulk_field}
          form={@bulk_form}
          type_options={@vehicle_type_choices}
          garage_options={@garage_choices}
          count={MapSet.size(@selected_ids)}
          return_focus_id={@bulk_drawer_return_focus_id}
        />

        <.confirm_dialog
          :if={@bulk_delete}
          id="bulk-delete-confirm"
          chrome="planner"
          open={true}
          title={"Delete #{Wording.count_noun(@bulk_delete.total, "vehicle")}?"}
          confirm_label={"Delete #{Wording.count_noun(@bulk_delete.total, "vehicle")}"}
          pending_label="Deleting…"
          on_confirm="confirm_delete_selected_vehicles"
          on_cancel="cancel_delete_selected_vehicles"
          described_by="bulk-delete-confirm-body"
          return_focus_id="bulk-delete"
        >
          <p>
            This removes them from {@current_organization.name}, with their type and garage. Fleet
            checks will use the lower count. You can't undo it.
          </p>
          <div class="mt-3 flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span>Vehicles:</span>
            <ul
              id="bulk-delete-ids"
              class="flex flex-wrap gap-x-1.5 font-semibold tabular-nums text-strong"
            >
              <li
                :for={vehicle_id <- @bulk_delete.shown}
                class="after:content-[','] last:after:content-['']"
              >
                {vehicle_id}
              </li>
            </ul>
            <span :if={@bulk_delete.remaining > 0} id="bulk-delete-more">
              and {@bulk_delete.remaining} more
            </span>
          </div>
        </.confirm_dialog>

        <.confirm_dialog
          :if={@type_delete_target}
          id="vehicle-type-delete-confirm"
          chrome="planner"
          open={true}
          title={"Delete #{@type_delete_target.name}?"}
          confirm_label="Delete type"
          pending_label="Deleting…"
          on_confirm="confirm_delete_vehicle_type"
          on_cancel="cancel_delete_vehicle_type"
          described_by="vehicle-type-delete-confirm-body"
          return_focus_id="delete-vehicle-type"
        >
          <p>
            This removes {@type_delete_target.name} from {@current_organization.name}. No vehicles
            use it.
          </p>
        </.confirm_dialog>

        <.confirm_dialog
          :if={@type_in_use}
          id="vehicle-type-in-use-dialog"
          chrome="planner"
          open={true}
          title={"Can't delete #{@type_in_use.vehicle_type.name}"}
          confirm_label="Close"
          cancel_label="Close"
          pending_label="Closing…"
          on_confirm="dismiss_vehicle_type_in_use"
          on_cancel="dismiss_vehicle_type_in_use"
          single_action={true}
          described_by="vehicle-type-in-use-dialog-body"
          return_focus_id="delete-vehicle-type"
        >
          <p>{in_use_message(@type_in_use.vehicle_type.name, @type_in_use.counts)}</p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # Types are the rows and garages the columns, so "how many of what, where" reads
  # without opening anything, and the rare job of editing a type sits beside the
  # counts. A vehicle with no garage or no type gets its own column or row, shown
  # only while one needs it. Below `md` each row is a card with one labelled line
  # per garage; `data-label` carries the garage name.
  attr :rows, :any, required: true, doc: "the `:vehicle_types` stream"
  attr :columns, :list, required: true
  attr :total, :integer, required: true
  attr :vehicles_empty?, :boolean, required: true

  defp fleet_matrix(assigns) do
    assigns =
      assigns
      |> assign(:total_label, if(assigns.vehicles_empty?, do: "Vehicles", else: "All garages"))
      |> assign(:zero, if(assigns.vehicles_empty?, do: "0", else: "—"))

    ~H"""
    <div
      role="region"
      aria-label="Fleet by type and garage"
      tabindex="0"
      class="overflow-x-auto focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus"
    >
      <table id="vehicle-types-table" class="w-full border-collapse text-left text-sm max-md:block">
        <caption class="sr-only">
          Vehicles by type and garage
        </caption>
        <thead class="max-md:hidden">
          <tr class="bg-canvas">
            <th scope="col" class={[matrix_head_class(), "pl-5"]}>Vehicle type</th>
            <th
              :for={column <- @columns}
              scope="col"
              class={[matrix_head_class(), "text-right", column.missing? && "text-warning-fg"]}
            >
              <span class="inline-flex items-center justify-end gap-1.5">
                <.icon :if={column.missing?} name="hero-exclamation-triangle" class="size-3.5" />
                {column.name}
              </span>
            </th>
            <th scope="col" class={[matrix_head_class(), "pr-5 text-right"]}>{@total_label}</th>
          </tr>
        </thead>
        <tbody id="vehicle-types-rows" phx-update="stream" class="max-md:block">
          <tr
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            class="border-t border-subtle hover:bg-canvas max-md:block max-md:px-4 max-md:py-3"
          >
            <th
              scope="row"
              class="py-0.5 pl-5 pr-4 text-left align-middle font-normal max-md:block max-md:p-0"
            >
              <button
                :if={row.type}
                id={"vehicle-type-name-#{row.type.id}"}
                type="button"
                phx-click="open_vehicle_type"
                phx-value-type_id={row.type.id}
                phx-value-opener_id={"vehicle-type-name-#{row.type.id}"}
                class={[
                  "inline-flex min-h-11 items-center rounded-control text-left text-sm font-[650] text-strong underline-offset-4 hover:underline",
                  focus_class()
                ]}
              >
                {row.type.name}
              </button>
              <span :if={row.type && limit_note(row.type.max_out_minutes)} class={matrix_note_class()}>
                {limit_note(row.type.max_out_minutes)}
              </span>
              <span
                :if={is_nil(row.type)}
                class="inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-warning-fg"
              >
                <.icon name="hero-exclamation-triangle" class="size-3.5" /> No type
              </span>
              <span :if={is_nil(row.type)} class={matrix_note_class()}>
                Assign a type so fleet checks can count these vehicles.
              </span>
            </th>
            <td
              :for={{count, column} <- Enum.zip(row.cells, @columns)}
              data-label={column.name}
              class={[matrix_cell_class(), count == 0 && "text-muted"]}
            >
              {if count == 0, do: @zero, else: count}
            </td>
            <td
              data-label={@total_label}
              class={[
                matrix_cell_class(),
                "pr-5",
                if(row.total == 0, do: "text-muted", else: "font-[650] text-strong")
              ]}
            >
              {if row.total == 0, do: @zero, else: row.total}
            </td>
          </tr>
        </tbody>
        <tfoot :if={!@vehicles_empty?} class="max-md:block">
          <tr class="h-12 border-t border-subtle bg-canvas max-md:block max-md:h-auto max-md:px-4 max-md:py-3">
            <th
              scope="row"
              class="py-0.5 pl-5 pr-4 text-left align-middle text-sm font-[650] text-strong max-md:block max-md:min-h-11 max-md:p-0 max-md:pt-2"
            >
              All vehicle types
            </th>
            <td
              :for={column <- @columns}
              data-label={column.name}
              class={[
                matrix_cell_class(),
                if(column.total == 0, do: "text-muted", else: "font-[650] text-strong")
              ]}
            >
              {if column.total == 0, do: @zero, else: column.total}
            </td>
            <td data-label={@total_label} class={[matrix_cell_class(), "pr-5 font-[650] text-strong"]}>
              {@total}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>
    """
  end

  defp matrix_head_class, do: "h-11 px-4 py-2.5 text-[13px] font-[650] text-default"

  # The vehicle list's column heads stay at the top of the viewport while a long
  # list scrolls under them. Below `md` the rows are cards, so the heads drop out.
  defp vehicle_head_class do
    [matrix_head_class(), "bg-canvas text-left md:sticky md:top-0 md:z-10 max-md:hidden"]
  end

  defp matrix_cell_class do
    [
      "px-4 text-right tabular-nums align-middle",
      "max-md:flex max-md:min-h-9 max-md:items-center max-md:justify-between max-md:px-0 max-md:text-left",
      "max-md:before:font-normal max-md:before:text-muted max-md:before:content-[attr(data-label)]"
    ]
  end

  defp matrix_note_class, do: "text-[13px] text-muted max-md:block lg:ml-2.5 lg:inline"

  defp focus_class,
    do: "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

  # A 44px target around the native checkbox. The design-system page scope removes
  # a checkbox's own outline, so the label draws the focus ring.
  defp checkbox_label_class do
    [
      "inline-flex min-h-11 min-w-11 cursor-pointer items-center justify-center rounded-control",
      "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-[-2px] has-[:focus-visible]:outline-focus"
    ]
  end

  # Below `md` a row is a card: the checkbox beside the number and label, then the
  # type, garage and plate, one to a line. Blank values drop out of the card
  # (`max-md:hidden` on the dash) instead of leaving an empty line.
  attr :rows, :any, required: true, doc: "the `:vehicles` stream"
  attr :selected_ids, :any, required: true
  attr :all_selected?, :boolean, required: true
  attr :count, :integer, required: true

  defp vehicles_table(assigns) do
    ~H"""
    <div id="vehicles-table-container">
      <table class="w-full border-collapse text-left text-sm max-md:block">
        <caption class="sr-only">
          Vehicles
        </caption>
        <thead class="max-md:block">
          <tr class="max-md:flex max-md:bg-canvas">
            <th
              scope="col"
              class="h-11 w-14 bg-canvas px-1 text-center md:sticky md:top-0 md:z-10 max-md:w-auto max-md:px-2 max-md:text-left"
            >
              <label class={[
                checkbox_label_class(),
                "max-md:gap-2 max-md:pr-3 max-md:text-[13px] max-md:font-[650] max-md:text-default"
              ]}>
                <input
                  id="select-all-vehicles"
                  type="checkbox"
                  class="size-[18px] accent-action"
                  checked={@all_selected?}
                  phx-click="select_all_filtered"
                />
                <span class="md:sr-only">Select all {Wording.count_noun(@count, "vehicle")}</span>
              </label>
            </th>
            <th scope="col" class={[vehicle_head_class(), "w-[150px]"]}>Vehicle number</th>
            <th scope="col" class={vehicle_head_class()}>Label</th>
            <th scope="col" class={vehicle_head_class()}>Type</th>
            <th scope="col" class={vehicle_head_class()}>Garage</th>
            <th scope="col" class={[vehicle_head_class(), "md:max-lg:hidden"]}>License plate</th>
          </tr>
        </thead>
        <tbody id="vehicles-table" phx-update="stream" class="max-md:block">
          <tr
            :for={{dom_id, vehicle} <- @rows}
            id={dom_id}
            class={[
              "border-t border-subtle hover:bg-canvas",
              "max-md:grid max-md:grid-cols-[44px_auto_minmax(0,1fr)] max-md:px-2 max-md:py-1",
              MapSet.member?(@selected_ids, vehicle.id) && "bg-selection"
            ]}
          >
            <td
              data-label="Select"
              class="w-14 p-0 text-center max-md:row-span-4 max-md:row-start-1 max-md:w-auto max-md:self-start"
            >
              <label class={checkbox_label_class()}>
                <input
                  id={"select-vehicle-#{vehicle.id}"}
                  type="checkbox"
                  class="size-[18px] accent-action"
                  checked={MapSet.member?(@selected_ids, vehicle.id)}
                  aria-label={"Select vehicle #{vehicle.vehicle_id}"}
                  phx-click="toggle_vehicle_selection"
                  phx-value-vehicle_id={vehicle.id}
                />
              </label>
            </td>
            <td
              data-label="Vehicle number"
              class="px-4 py-0 max-md:col-start-2 max-md:row-start-1 max-md:px-0"
            >
              <button
                id={"vehicle-id-#{vehicle.id}"}
                type="button"
                phx-click="open_vehicle"
                phx-value-vehicle_id={vehicle.id}
                phx-value-opener_id={"vehicle-id-#{vehicle.id}"}
                class={[
                  "inline-flex min-h-11 min-w-11 items-center rounded-control text-left text-sm font-[650] tabular-nums text-strong underline-offset-4 hover:underline",
                  focus_class()
                ]}
              >
                {vehicle.vehicle_id}
              </button>
            </td>
            <td
              data-label="Label"
              class="px-4 py-2 max-md:col-start-3 max-md:row-start-1 max-md:p-0 max-md:pl-1 max-md:text-[13px] max-md:text-muted"
            >
              <span :if={Values.blank?(vehicle.vehicle_label)} class="text-muted max-md:hidden">
                —
              </span>
              <span :if={!Values.blank?(vehicle.vehicle_label)}>{vehicle.vehicle_label}</span>
            </td>
            <td
              data-label="Type"
              class="px-4 py-2 max-md:col-span-2 max-md:col-start-2 max-md:row-start-2 max-md:p-0 max-md:py-0.5"
            >
              <.missing_badge :if={is_nil(vehicle.vehicle_type)} label="No type" />
              <span :if={vehicle.vehicle_type}>{vehicle.vehicle_type.name}</span>
            </td>
            <td
              data-label="Garage"
              class="px-4 py-2 max-md:col-span-2 max-md:col-start-2 max-md:row-start-3 max-md:p-0 max-md:py-0.5"
            >
              <.missing_badge :if={is_nil(vehicle.garage)} label="No garage" />
              <span :if={vehicle.garage}>{vehicle.garage.name}</span>
            </td>
            <td
              data-label="License plate"
              class="px-4 py-2 tabular-nums md:max-lg:hidden max-md:col-span-2 max-md:col-start-2 max-md:row-start-4 max-md:p-0 max-md:pb-1 max-md:text-[13px] max-md:text-muted"
            >
              <span :if={Values.blank?(vehicle.license_plate)} class="text-muted max-md:hidden">
                —
              </span>
              <span :if={!Values.blank?(vehicle.license_plate)}>{vehicle.license_plate}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # What a vehicle shows when its type or garage is unset. It carries a word and an
  # icon as well as the warning colour, and marks the cell for tests and hooks.
  attr :label, :string, required: true

  defp missing_badge(assigns) do
    ~H"""
    <span
      data-unassigned
      class="inline-flex items-center gap-1.5 rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] text-warning-fg"
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5" /> {@label}
    </span>
    """
  end

  defp focus_vehicle_form_error(socket) do
    push_event(socket, "focus_form_error", %{
      form_id: @vehicle_form_id,
      fallback_id: @vehicle_form_error_id
    })
  end

  # A submit does not set the form's params, so a refused batch re-assigns them
  # from the payload: the entries and the preview survive the refusal.
  defp assign_vehicle_range(socket, params) do
    socket
    |> assign(:range_form, vehicle_range_form(params))
    |> assign(:range_preview, range_preview_message(params["first"], params["last"]))
  end

  defp delete_vehicle_type(socket, vehicle_type) do
    case Operations.delete_vehicle_type(
           socket.assigns.current_organization.id,
           actor(socket),
           vehicle_type.id
         ) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> assign(:type_delete_target, nil)
         |> close_vehicle_type_drawer()
         |> load_fleet()
         |> assign(:type_notice, "#{deleted.name} deleted.")}

      {:error, {:in_use, counts}} ->
        {:noreply,
         socket
         |> assign(:type_delete_target, nil)
         |> show_type_in_use(vehicle_type, counts)}

      {:error, :not_found} ->
        {:noreply, socket |> assign(:type_delete_target, nil) |> load_fleet()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, @permission_error)}
    end
  end

  attr :open, :boolean, required: true
  attr :title, :string, required: true
  attr :entity, :any, default: nil
  attr :counts, :map, default: nil
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
      chrome="planner"
      open={@open}
      on_close="close_vehicle_type_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[560px]"
    >
      <:lede>
        <span id="vehicle-type-drawer-scope">{type_drawer_scope(@entity)}</span>
      </:lede>

      <div
        id="vehicle-type-drawer-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_vehicle_type"
          phx-submit="save_vehicle_type"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={save_failed?(@form)}
              id={@form_error_id}
              kind="error"
              title="Vehicle type not saved"
              tabindex="-1"
            >
              Fix the fields marked below, then save again.
            </.message>

            <p id="vehicle-type-drawer-description" class="text-sm text-muted">
              Only the type name is required.
            </p>

            <.input
              field={@form[:name]}
              type="text"
              label="Type name"
              help="Include the size and floor type, such as “35-foot low-floor bus”. Each name can be used once."
              autocomplete="off"
            />

            <.input
              field={@form[:max_out_hours]}
              type="number"
              min="1"
              max="24"
              step="0.25"
              label="Longest time away from garage, in hours (optional)"
              class="w-full input input-lg max-w-[140px]"
              help="From 1 to 24 hours. Leave blank for no limit. Set it for vehicles that must recharge or refuel, such as battery-electric buses."
            />

            <.message
              :if={@entity}
              id="vehicle-type-assigned-vehicles"
              kind={if Operations.in_use?(@counts), do: "warning", else: "info"}
              title={type_use_title(@counts)}
            >
              {if Operations.in_use?(@counts),
                do: "To delete it, first change those.",
                else: "You can delete it without changing anything."}
            </.message>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              :if={@entity}
              id="delete-vehicle-type"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 text-error-fg hover:bg-error-bg"
              phx-click="delete_vehicle_type"
              phx-value-type_id={@entity.id}
            >
              <.icon name="hero-trash" class="size-4" /> Delete type
            </.button>
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_vehicle_type_drawer"
            >
              Cancel
            </.button>
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">Save type</.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  attr :open, :boolean, required: true
  attr :title, :string, required: true
  attr :mode, :atom, required: true
  attr :entity, :any, default: nil
  attr :form, :any, required: true
  attr :range_form, :any, required: true
  attr :type_options, :list, required: true
  attr :garage_options, :list, required: true
  attr :range_preview, :any, required: true
  attr :error, :string, default: nil
  attr :return_focus_id, :string, default: nil

  defp vehicle_drawer(assigns) do
    assigns =
      assigns
      |> assign(:form_id, @vehicle_form_id)
      |> assign(:form_error_id, @vehicle_form_error_id)
      |> assign(:range_form_id, @range_form_id)
      # Adding always opens on the one-vehicle form, so the field that takes
      # focus on open is fixed. Switching mode keeps focus on the mode control
      # the operator just used; the form's own first field is one Tab away.
      |> assign(:focus_field_id, "vehicle_vehicle_id")
      |> assign(:type_help, type_select_help(assigns.type_options))

    ~H"""
    <.drawer
      id="vehicle-drawer"
      chrome="planner"
      open={@open}
      on_close="close_vehicle_drawer"
      title={@title}
      initial_focus={:first_field}
      initial_focus_id={@focus_field_id}
      return_focus_id={@return_focus_id}
      class="max-w-[560px]"
    >
      <:lede>
        <span id="vehicle-drawer-scope">{vehicle_drawer_scope(@entity)}</span>
      </:lede>

      <div id="vehicle-drawer-content" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <%!-- The mode switch is its own form, so it sits above the vehicle form rather
        than inside it. --%>
        <div class="grid justify-items-start gap-5 px-5 pt-5 sm:px-6">
          <p id="vehicle-drawer-description" class="text-sm text-muted">
            {vehicle_drawer_description(@entity, @mode)}
          </p>

          <.segmented_control
            :if={is_nil(@entity)}
            id="vehicle-mode"
            name="vehicle_mode"
            legend="How many vehicles?"
            legend_class="mb-1.5 text-[13px] font-[650] text-default"
            options={[{"One vehicle", "single"}, {"Numbered group", "range"}]}
            value={Atom.to_string(@mode)}
            event="select_vehicle_mode"
            appearance={:joined}
            emphasis={:selection}
          />
        </div>

        <.form
          :if={@mode == :single or not is_nil(@entity)}
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_vehicle"
          phx-submit="save_vehicle"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={is_nil(@error) and save_failed?(@form)}
              id={@form_error_id}
              kind="error"
              title="Vehicle not saved"
              tabindex="-1"
            >
              Fix the fields marked below, then save again.
            </.message>

            <.input
              field={@form[:vehicle_id]}
              type="text"
              label="Vehicle number"
              help="The number on the vehicle. Letters are allowed, such as A12."
              autocomplete="off"
              spellcheck="false"
            />

            <.input
              field={@form[:vehicle_type_id]}
              type="select"
              label="Vehicle type (optional)"
              prompt="No type"
              options={@type_options}
              help={@type_help}
            />

            <.input
              field={@form[:garage_id]}
              type="select"
              label="Garage (optional)"
              prompt="No garage"
              options={@garage_options}
              help={garage_select_help()}
            />

            <.input
              field={@form[:vehicle_label]}
              type="text"
              label="Label (optional)"
              help="A name drivers use, such as “Electric 1”."
              autocomplete="off"
            />

            <.input
              field={@form[:license_plate]}
              type="text"
              label="License plate (optional)"
              autocomplete="off"
              spellcheck="false"
            />
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_vehicle_drawer"
            >
              Cancel
            </.button>
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">
              {if @entity, do: "Save vehicle", else: "Add vehicle"}
            </.button>
          </.drawer_footer>
        </.form>

        <.form
          :if={@mode == :range and is_nil(@entity)}
          for={@range_form}
          id={@range_form_id}
          novalidate
          phx-change="validate_vehicle_range"
          phx-submit="save_vehicle"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={@error}
              id={@form_error_id}
              kind="error"
              title="Nothing was saved"
              tabindex="-1"
            >
              {@error}
            </.message>

            <div class="grid grid-cols-2 items-start gap-3">
              <.input
                field={@range_form[:first]}
                type="text"
                inputmode="numeric"
                label="First number"
                autocomplete="off"
                spellcheck="false"
              />

              <.input
                field={@range_form[:last]}
                type="text"
                inputmode="numeric"
                label="Last number"
                autocomplete="off"
                spellcheck="false"
              />
            </div>

            <%!-- The preview is feedback; the context still decides the save. Leading
            zeros are kept, so the padded IDs it names are the ones that are added. --%>
            <div class="grid gap-1.5">
              <p
                id="range-preview"
                aria-live="polite"
                class={[
                  "rounded-control bg-canvas px-3 py-2.5 text-sm",
                  if(@range_preview.ok?, do: "font-[650] text-strong", else: "text-muted")
                ]}
              >
                {@range_preview.text}
              </p>
              <p class="text-[13px] text-muted">
                Leading zeros are kept, so 0098 to 0102 adds five vehicles.
              </p>
            </div>

            <.input
              field={@range_form[:vehicle_type_id]}
              type="select"
              label="Vehicle type (optional)"
              prompt="No type"
              options={@type_options}
              help={@type_help}
            />

            <.input
              field={@range_form[:garage_id]}
              type="select"
              label="Garage (optional)"
              prompt="No garage"
              options={@garage_options}
              help={garage_select_help()}
            />
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_vehicle_drawer"
            >
              Cancel
            </.button>
            <.button type="submit" class="min-h-11" phx-disable-with="Adding…">
              Add vehicles
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  attr :open, :boolean, required: true
  attr :field, :atom, default: nil
  attr :form, :any, required: true
  attr :type_options, :list, required: true
  attr :garage_options, :list, required: true
  attr :count, :integer, required: true
  attr :return_focus_id, :string, default: nil

  defp bulk_drawer(assigns) do
    assigns =
      assigns
      |> assign(:form_id, @bulk_form_id)
      |> assign(:title, bulk_drawer_title(assigns.field))
      |> assign(:noun, bulk_field_noun(assigns.field))
      |> assign(:field_label, bulk_field_label(assigns.field))
      |> assign(
        :options,
        bulk_field_options(assigns.field, assigns.type_options, assigns.garage_options)
      )

    ~H"""
    <.drawer
      id="bulk-drawer"
      chrome="planner"
      open={@open}
      on_close="close_bulk_drawer"
      title={@title}
      initial_focus={:first_field}
      initial_focus_id="bulk_value"
      return_focus_id={@return_focus_id}
      class="max-w-[520px]"
    >
      <:lede>
        <span id="bulk-drawer-scope">{Wording.count_noun(@count, "vehicle")} selected</span>
      </:lede>

      <div id="bulk-drawer-content" class="flex min-h-0 flex-1 flex-col">
        <.form
          for={@form}
          id={@form_id}
          phx-submit="save_bulk_assignment"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <p id="bulk-drawer-description" class="text-sm text-default">
              Update {Wording.count_noun(@count, "vehicle")} at once. The {@noun} you choose replaces the current one on every selected vehicle.
            </p>

            <.input
              field={@form[:value]}
              type="select"
              label={@field_label}
              prompt={"No #{@noun}"}
              options={@options}
              help={"Choose No #{@noun} to clear it."}
            />
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_bulk_drawer"
            >
              Cancel
            </.button>
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">{@title}</.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  # --- fleet state -----------------------------------------------------------

  defp refresh_fleet(socket, params, uri) do
    filters = filters_from_params(params)

    socket
    |> assign(:fleet_query, fleet_query(uri))
    |> assign(:fleet_filters, filters)
    |> assign(:filters_form, filters_form(filters))
    |> assign(:filters_active?, filters_active?(filters))
    |> assign(:bulk_error, nil)
    |> assign(:selected_ids, MapSet.new())
    |> load_fleet()
  end

  # The current filters as the query map the verified route encodes, so a
  # version switch rebuilds the URL from the parameters rather than re-encoding
  # a query string that is already encoded.
  defp fleet_query(uri) do
    case URI.parse(uri).query do
      nil -> nil
      "" -> nil
      query -> Query.decode(query)
    end
  end

  # A file that finished uploading is parsed and previewed immediately, so the
  # drawer always shows the plan for the file the operator chose. `Tods.parse/3`
  # returns `{:error, message}` for a structural fault, which blocks the preview.
  defp handle_tods_file_progress(:tods_file, entry, socket) do
    if entry.done? do
      {:noreply, review_tods_file(socket, entry)}
    else
      # A newly chosen file replaces the review on screen; whatever was reviewed
      # before it must not stay applicable while this one uploads.
      {:noreply, reset_tods_import_review(socket)}
    end
  end

  defp review_tods_file(socket, entry) do
    file = entry.client_name
    organization_id = socket.assigns.current_organization.id

    case consume_uploaded_entry(socket, entry, fn uploaded ->
           {:ok, parse_tods_file(uploaded, file)}
         end) do
      {:ok, parsed} ->
        socket
        |> assign(:tods_import_filename, file)
        |> assign(:tods_import_parsed, parsed)
        |> assign(:tods_import_preview, Operations.preview_tods_import(organization_id, parsed))
        |> assign(:tods_import_parse_error, nil)
        |> assign(:tods_import_stale?, false)

      {:error, message} ->
        socket
        |> assign(:tods_import_filename, file)
        |> assign(:tods_import_parsed, nil)
        |> assign(:tods_import_preview, nil)
        |> assign(:tods_import_parse_error, message)
        |> assign(:tods_import_stale?, false)
    end
  end

  defp parse_tods_file(%{path: path}, file) do
    case File.read(path) do
      {:ok, content} -> Tods.parse(:vehicles, file, content)
      {:error, _reason} -> {:error, "#{file} could not be read."}
    end
  end

  defp apply_reviewed_tods_import(socket, parsed, preview) do
    organization_id = socket.assigns.current_organization.id

    case Operations.apply_tods_import(organization_id, actor(socket), parsed, preview) do
      {:ok, %{added: added, updated: updated}} ->
        {:noreply,
         socket
         |> reset_tods_import_review()
         |> assign(:tods_import_open, false)
         |> load_fleet()
         |> assign(:vehicle_notice, "Vehicles imported: #{added} added, #{updated} updated.")}

      # The context refuses a plan whose recomputed rows differ and hands back the
      # refreshed preview, so the drawer keeps the reviewed state visible, swaps in
      # the new counts and moves focus to the message.
      {:error, {_reason, refreshed_preview}} ->
        {:noreply,
         socket
         |> assign(:tods_import_preview, refreshed_preview)
         |> assign(:tods_import_stale?, true)
         |> push_event("focus_scoped_target", %{id: "tods-import-error"})}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, @permission_error)}
    end
  end

  # The review describes exactly one upload: closing the drawer, cancelling the
  # upload, choosing another file and a successful apply all drop it. The opener
  # id survives so the OverlayDialog hook can still return focus to the trigger.
  defp reset_tods_import_review(socket) do
    socket
    |> assign(:tods_import_filename, nil)
    |> assign(:tods_import_parsed, nil)
    |> assign(:tods_import_preview, nil)
    |> assign(:tods_import_parse_error, nil)
    |> assign(:tods_import_stale?, false)
  end

  defp discard_tods_upload(socket) do
    Enum.reduce(socket.assigns.uploads.tods_file.entries, socket, fn entry, acc ->
      cancel_upload(acc, :tods_file, entry.ref)
    end)
  end

  # Loads every list the page renders from the current filter state. A URL
  # change, a type mutation and a vehicle mutation all reuse it, so a renamed
  # type's name also updates the vehicle rows and the summary breakdown without a
  # separate query path.
  defp load_fleet(socket) do
    organization_id = socket.assigns.current_organization.id

    vehicles =
      Operations.list_vehicles(organization_id, filter_values(socket.assigns.fleet_filters))

    summary = Operations.fleet_summary(organization_id)
    vehicle_types = Operations.list_vehicle_types(organization_id)
    garages = Operations.list_garages(organization_id)
    counts = summary_counts(summary)
    matrix = fleet_matrix_data(summary, vehicle_types, garages)

    socket
    |> assign(:vehicle_type_choices, Enum.map(vehicle_types, &{&1.name, &1.id}))
    |> assign(:garage_choices, Enum.map(garages, &{&1.name, &1.id}))
    |> assign(:vehicle_type_options, vehicle_type_options(vehicle_types))
    |> assign(:garage_options, garage_options(garages))
    |> assign(:total_count, counts.total)
    |> assign(:filtered_count, length(vehicles))
    |> assign(:filtered_vehicles, vehicles)
    |> assign(:needs_assignment_count, counts.needs_assignment)
    |> assign(:matrix_columns, matrix.columns)
    |> assign(:vehicles_empty?, counts.total == 0)
    |> assign(:vehicle_types_empty?, vehicle_types == [])
    |> stream(:vehicles, vehicles, reset: true)
    |> stream(:vehicle_types, matrix.rows, reset: true)
  end

  # The option lists are the organization's own rows, ordered by name, so they
  # are rebuilt from the loaded rows on every refresh rather than cached across
  # a mutation. The filters append "No type" and "No garage", which are the `none`
  # filter the context accepts and selects the rows whose type or garage is nil; the
  # drawer spends only a blank prompt on the same state, which clears the assignment.
  defp vehicle_type_options(vehicle_types) do
    Enum.map(vehicle_types, &{&1.name, &1.id}) ++ [{"No type", "none"}]
  end

  defp garage_options(garages) do
    Enum.map(garages, &{&1.name, &1.id}) ++ [{"No garage", "none"}]
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
      q: Values.presence(filters["q"])
    }
  end

  # The drawer's "none" sentinel is its own value; blank handling follows Values.presence/1.
  defp assignment_value("none"), do: :none
  defp assignment_value(value), do: Values.presence(value)

  defp filters_active?(filters) do
    Enum.any?(~w(type garage), &(filters[&1] != "")) or Values.presence(filters["q"]) != nil
  end

  defp filter_query_params(params) do
    %{}
    |> Values.put_present("q", params["q"])
    |> Values.put_present("type", params["type"])
    |> Values.put_present("garage", params["garage"])
  end

  defp fleet_url(socket, query) do
    fleet_path(socket.assigns.current_gtfs_version.id, query)
  end

  # --- vehicle drawer state --------------------------------------------------

  defp actor(socket) do
    %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
  end

  defp vehicle_form(vehicle, attrs) do
    vehicle
    |> Operations.change_vehicle(attrs)
    |> to_form(as: :vehicle)
  end

  # The type and garage selects are outside `Vehicle.changeset/2`'s cast list,
  # because the context validates each assignment against the organization
  # before it writes. `to_form/2` still reads them from the vehicle struct (or
  # from the submitted params), so the drawer shows the stored assignment and
  # keeps the operator's choice across a change event.
  defp vehicle_base(socket), do: socket.assigns.vehicle_entity || %Vehicle{}

  # A numbered group has no schema to change: the four entries are handed to
  # `Operations.create_vehicle_range/3` unchanged and the context validates them.
  defp vehicle_range_form(attrs) do
    types = %{first: :string, last: :string, vehicle_type_id: :string, garage_id: :string}

    {%{}, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> to_form(as: :range)
  end

  defp vehicle_mode("single"), do: :single
  defp vehicle_mode("range"), do: :range
  defp vehicle_mode(_mode), do: nil

  defp open_add_vehicle(socket, opener_id) do
    socket
    |> assign(:vehicle_entity, nil)
    |> assign(:vehicle_mode, :single)
    |> assign(:vehicle_form, vehicle_form(%Vehicle{}, %{}))
    |> assign(:range_form, vehicle_range_form(%{}))
    |> assign(:range_preview, range_preview_message("", ""))
    |> assign(:vehicle_drawer_title, "Add vehicles")
    |> assign(:vehicle_drawer_return_focus_id, opener_id)
    |> assign(:vehicle_notice, nil)
    |> assign(:vehicle_error, nil)
    |> assign(:vehicle_drawer_open, true)
  end

  defp open_edit_vehicle(socket, vehicle, opener_id) do
    socket
    |> assign(:vehicle_entity, vehicle)
    |> assign(:vehicle_mode, :single)
    |> assign(:vehicle_form, vehicle_form(vehicle, %{}))
    |> assign(:vehicle_drawer_title, "Edit vehicle")
    |> assign(:vehicle_drawer_return_focus_id, opener_id)
    |> assign(:vehicle_notice, nil)
    |> assign(:vehicle_error, nil)
    |> assign(:vehicle_drawer_open, true)
  end

  # Switching modes starts the other form empty, as the reference drawer does;
  # the opener id survives the close so the OverlayDialog hook can still read it.
  defp switch_vehicle_mode(socket, mode) do
    socket
    |> assign(:vehicle_mode, mode)
    |> assign(:vehicle_form, vehicle_form(%Vehicle{}, %{}))
    |> assign(:range_form, vehicle_range_form(%{}))
    |> assign(:range_preview, range_preview_message("", ""))
    |> assign(:vehicle_error, nil)
  end

  defp close_vehicle_drawer(socket) do
    socket
    |> assign(:vehicle_drawer_open, false)
    |> assign(:vehicle_entity, nil)
    |> assign(:vehicle_mode, :single)
    |> assign(:vehicle_error, nil)
  end

  # The row trigger carries the vehicle's UUID, so the drawer re-reads the
  # organization's own rows rather than trusting the event; a malformed or
  # foreign id selects nothing.
  defp load_vehicle(socket, id) when is_binary(id) do
    socket.assigns.current_organization.id
    |> Operations.list_vehicles(%{})
    |> Enum.find(&(&1.id == id))
  end

  defp load_vehicle(_socket, _id), do: nil

  # --- bulk selection state --------------------------------------------------

  # Only the rows the page is currently streaming are re-inserted: a crafted id
  # that is not on screen stays in the selection (the context refuses it on the
  # write) but must not inject a row into the stream.
  defp restream_vehicles(socket, ids) do
    Enum.reduce(ids, socket, fn id, socket ->
      case Enum.find(socket.assigns.filtered_vehicles, &(&1.id == id)) do
        nil -> socket
        vehicle -> stream_insert(socket, :vehicles, vehicle)
      end
    end)
  end

  defp clear_selection(socket) do
    socket
    |> reset_selection()
    |> restream_vehicles(Enum.map(socket.assigns.filtered_vehicles, & &1.id))
  end

  # Dropping the set needs no re-stream of its own where `load_fleet/1` follows:
  # that reset re-renders every row from the now-empty selection.
  defp reset_selection(socket), do: assign(socket, :selected_ids, MapSet.new())

  defp toggle_selection(selected, id) do
    if MapSet.member?(selected, id) do
      MapSet.delete(selected, id)
    else
      MapSet.put(selected, id)
    end
  end

  defp empty_selection?(selected), do: MapSet.size(selected) == 0

  defp all_filtered_selected?(_selected, []), do: false

  defp all_filtered_selected?(selected, vehicles) do
    Enum.all?(vehicles, &MapSet.member?(selected, &1.id))
  end

  # The two assignment fields the context accepts, spelled as the select's
  # `phx-value-field`; anything else is refused rather than guessed.
  defp bulk_field("type"), do: :vehicle_type_id
  defp bulk_field("garage"), do: :garage_id
  defp bulk_field(_field), do: nil

  # The blank prompt is “Not assigned”, which clears the assignment; every other
  # value reaches the context unchanged so its ownership check decides.
  # Named exception: a forged non-binary must not clear an assignment, so only nil/"" become nil.
  defp bulk_target(value) when value in [nil, ""], do: nil
  defp bulk_target(value), do: value

  defp bulk_drawer_title(:garage_id), do: "Set garage"
  defp bulk_drawer_title(_field), do: "Set type"

  defp bulk_field_label(:vehicle_type_id), do: "Vehicle type"
  defp bulk_field_label(_field), do: "Garage"

  defp bulk_field_options(:vehicle_type_id, type_options, _garage_options), do: type_options
  defp bulk_field_options(:garage_id, _type_options, garage_options), do: garage_options
  defp bulk_field_options(_field, _type_options, _garage_options), do: []

  defp bulk_form(attrs) do
    {%{}, %{value: :string}}
    |> Ecto.Changeset.cast(attrs, [:value])
    |> to_form(as: :bulk)
  end

  defp bulk_updated_notice(:vehicle_type_id, count),
    do: "Type updated on #{Wording.count_noun(count, "vehicle")}."

  defp bulk_updated_notice(:garage_id, count),
    do: "Garage updated on #{Wording.count_noun(count, "vehicle")}."

  # What the confirmation dialog names: the selected vehicles still on screen, in
  # list order, plus the count of selected ids it cannot name (a crafted or
  # already-deleted id), so the request's size is never understated.
  defp bulk_delete_summary(socket) do
    selected = socket.assigns.selected_ids
    total = MapSet.size(selected)

    shown =
      socket.assigns.filtered_vehicles
      |> Enum.filter(&MapSet.member?(selected, &1.id))
      |> Enum.map(& &1.vehicle_id)
      |> Enum.take(@bulk_name_limit)

    %{total: total, shown: shown, remaining: total - length(shown)}
  end

  # The context refused the write, so nothing changed: report it, drop the stale
  # selection and reload the list the operator is looking at.
  defp stale_selection(socket) do
    socket
    |> assign(:bulk_drawer_open, false)
    |> assign(:bulk_delete, nil)
    |> assign(:bulk_error, "Some vehicles are no longer available. The list has been refreshed.")
    |> reset_selection()
    |> load_fleet()
  end

  # The same padding rule `Operations.create_vehicle_range/3` applies, stated
  # here so the operator sees which IDs a group will claim before saving.
  # `0098`–`0102` reads as five four-digit IDs. Anything the rule cannot accept
  # falls back to the limit sentence, and the context still decides the save.
  defp range_preview_message(first, last) do
    case range_preview_ids(first, last) do
      {:ok, ids} ->
        %{
          ok?: true,
          text:
            "Adds #{hd(ids)}–#{List.last(ids)} (#{Wording.count_noun(length(ids), "vehicle")})"
        }

      :error ->
        %{ok?: false, text: "Choose a numbered group of 1 to 200 vehicles."}
    end
  end

  defp range_preview_ids(first, last) do
    with {:ok, first_value, width} <- range_preview_bound(first),
         {:ok, last_value, _last_digits} <- range_preview_bound(last),
         {:ok, count} <- range_preview_count(first_value, last_value) do
      range_preview_padded_ids(first_value, count, width)
    else
      :error -> :error
    end
  end

  defp range_preview_count(first_value, last_value) do
    count = last_value - first_value + 1

    if count in 1..@range_limit, do: {:ok, count}, else: :error
  end

  defp range_preview_padded_ids(first_value, count, width) do
    ids =
      Enum.map(
        first_value..(first_value + count - 1),
        &String.pad_leading(Integer.to_string(&1), width, "0")
      )

    if Enum.all?(ids, &(String.length(&1) <= @max_vehicle_id_length)),
      do: {:ok, ids},
      else: :error
  end

  defp range_preview_bound(value) when is_binary(value) do
    digits = String.trim(value)

    cond do
      String.length(digits) > @max_vehicle_id_length -> :error
      Regex.match?(~r/^\d+$/, digits) -> {:ok, String.to_integer(digits), String.length(digits)}
      true -> :error
    end
  end

  defp range_preview_bound(_value), do: :error

  defp vehicle_saved_notice(vehicle_id, true), do: "#{vehicle_id} saved."
  defp vehicle_saved_notice(vehicle_id, false), do: "#{vehicle_id} added."

  defp vehicles_added_notice(count), do: "#{Wording.count_noun(count, "vehicle")} added."

  defp ids_taken_message(ids) do
    "No vehicles were added. These IDs already exist: #{Enum.join(ids, ", ")}. Choose unused numbers."
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
    |> assign(
      :type_counts,
      Operations.vehicle_type_in_use_counts(
        socket.assigns.current_organization.id,
        vehicle_type.id
      )
    )
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

  # Only a set limit is worth a note: "no limit" is the default and would repeat
  # on every row. Stored minutes are whole; a quarter-hour step keeps the hour
  # value short.
  defp limit_note(nil), do: nil

  defp limit_note(minutes) when is_integer(minutes) do
    hours =
      minutes
      |> Decimal.new()
      |> Decimal.div(60)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    "Up to #{hours} #{if hours == "1", do: "hour", else: "hours"} away"
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

  # The count matrix: one row per type and one column per garage, from the same
  # garage x type buckets as the totals. A garage with no vehicles still gets a
  # column so the matrix shows where the fleet is not. A "No garage" column and a
  # "No type" row appear only while a vehicle needs them, so no vehicle is left
  # out of a total. With no vehicles there are no columns: the rows are the types
  # and one count of zero.
  defp fleet_matrix_data(summary, vehicle_types, garages) do
    counts = Map.new(summary, &{{id_of(&1.vehicle_type), id_of(&1.garage)}, &1.count})
    vehicles? = summary != []

    garage_columns =
      if vehicles?,
        do: Enum.map(garages, &%{id: &1.id, name: &1.name, missing?: false}),
        else: []

    columns =
      if Enum.any?(summary, &is_nil(&1.garage)),
        do: garage_columns ++ [%{id: nil, name: "No garage", missing?: true}],
        else: garage_columns

    columns =
      Enum.map(columns, fn column ->
        Map.put(
          column,
          :total,
          sum_counts(counts, fn {_type_id, garage_id} -> garage_id == column.id end)
        )
      end)

    type_rows = Enum.map(vehicle_types, &matrix_row(&1.id, &1, columns, counts))

    rows =
      if Enum.any?(summary, &is_nil(&1.vehicle_type)),
        do: type_rows ++ [matrix_row("none", nil, columns, counts)],
        else: type_rows

    %{columns: columns, rows: rows}
  end

  defp matrix_row(id, type, columns, counts) do
    type_id = id_of(type)

    %{
      id: id,
      type: type,
      cells: Enum.map(columns, &Map.get(counts, {type_id, &1.id}, 0)),
      total: sum_counts(counts, fn {row_type_id, _garage_id} -> row_type_id == type_id end)
    }
  end

  defp sum_counts(counts, keep?) do
    counts
    |> Enum.filter(fn {key, _count} -> keep?.(key) end)
    |> Enum.map(fn {_key, count} -> count end)
    |> Enum.sum()
  end

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id

  defp types_help(true, _vehicles_empty?), do: "Types group vehicles that do the same work."

  defp types_help(false, true),
    do: "Select a type name to edit it. Counts appear once you add vehicles."

  defp types_help(false, false), do: "Select a type name to edit it."

  defp count_summary(_filtered, total, false), do: Wording.count_noun(total, "vehicle")

  defp count_summary(filtered, total, true),
    do: "#{filtered} of #{Wording.count_noun(total, "vehicle")}"

  defp needs_assignment_title(1), do: "1 vehicle needs a garage or type"
  defp needs_assignment_title(count), do: "#{count} vehicles need a garage or type"

  # The drawer states the same references the delete is refused on, read when
  # the drawer opens and again when a delete is refused.
  defp type_use_title(counts) do
    case in_use_summary(counts) do
      nil -> "Nothing uses this type"
      summary -> "Used by #{summary}"
    end
  end

  # The refusal's counts are current; the counts the drawer opened with may not be.
  defp show_type_in_use(socket, vehicle_type, counts) do
    socket
    |> assign(:type_counts, counts)
    |> assign(:type_in_use, %{vehicle_type: vehicle_type, counts: counts})
  end

  defp vehicle_drawer_scope(nil), do: "Shared across all service versions"

  defp vehicle_drawer_scope(vehicle),
    do: "Vehicle #{vehicle.vehicle_id} · shared across all service versions"

  defp vehicle_drawer_description(nil, :range),
    do: "Adds every number from the first to the last, up to 200 at once."

  defp vehicle_drawer_description(_entity, _mode), do: "Only the vehicle number is required."

  defp type_drawer_scope(nil),
    do: "Group vehicles that do the same work · applies to every service version"

  defp type_drawer_scope(vehicle_type),
    do: "#{vehicle_type.name} · applies to every service version"

  defp type_select_help([]), do: "No vehicle types yet. You can assign one later."
  defp type_select_help(_options), do: nil

  # Both drawers' garage selects say what an unassigned vehicle costs: fleet checks
  # may leave it out.
  defp garage_select_help,
    do: "Fleet checks may not count a vehicle until it has a type and a garage."

  defp bulk_field_noun(:garage_id), do: "garage"
  defp bulk_field_noun(_field), do: "type"

  # The Fleet query string carries its filters, so a version switch keeps it in
  # the URL instead of dropping the operator's current view. The query reaches
  # the verified route as the filter map, never as an already-encoded string,
  # which `~p` would encode a second time.
  defp fleet_path(version_id, query) when query in [nil, ""] do
    ~p"/gtfs/#{version_id}/settings/fleet"
  end

  defp fleet_path(version_id, query) do
    ~p"/gtfs/#{version_id}/settings/fleet?#{query}"
  end
end
