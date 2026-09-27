defmodule GtfsPlannerWeb.Gtfs.GaragesLive do
  @moduledoc """
  LiveView for the organization's garages: the list, the add/edit drawer and
  the guarded delete flow.

  Garages belong to the organization and ignore GTFS versions: the version in
  the URL is navigation context and selects which `stops.stop_id` values the
  conflict notice compares against. Access is authorized at mount through
  `EnsureRole`, following the other GTFS pages — there is no view-only GTFS role,
  and the context enforces tenancy on every call.

  The drawer reuses the shared `drawer/1`, `input/1`, `callout/1` and
  `confirm_dialog/1` components and the gallery's `LiveSelect` autocomplete
  pattern. `Garage.changeset/2` owns validation, so a rejected submit returns
  focus to the first invalid field through the scoped `FormErrorFocus` hook.

  `garage_id` is a correctable external ID: creation derives it from the name
  until the user edits the ID field (tracked from the form event's `_target`),
  and a saved garage's ID is never regenerated from a name change.

  "Import from TODS file" opens the shared `tods_import_drawer/1`: the chosen
  file is parsed by `Tods` and previewed through `Operations.preview_tods_import/2`,
  and only the reviewed plan may be applied. The review describes exactly one
  upload, so closing the drawer, cancelling the upload or choosing another file
  discards it rather than leaving a plan that no longer matches the screen.
  """

  require Logger

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents,
    only: [scope_note: 1, tods_import_drawer: 1, tods_review_current?: 2]

  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Versions
  alias LiveSelect.Component, as: LiveSelectComponent

  @garage_id_field "garage_id"
  @garage_address_field "address"
  @garage_form_id "garage-form"
  @garage_form_error_id "garage-form-error"

  # LiveView normalizes a form event's `_target` into the changed field's key
  # path, so both the browser and LiveViewTest deliver `["garage", "<field>"]`.
  @garage_id_target ["garage", "garage_id"]
  @garage_address_target ["garage", "address"]

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
     |> assign(:garage_notice, nil)
     |> assign(:garage_drawer_open, false)
     |> assign(:garage_entity, nil)
     |> assign(:garage_form, garage_form(%Garage{}, %{}))
     |> assign(:garage_drawer_title, "Add garage")
     |> assign(:garage_drawer_return_focus_id, nil)
     |> assign(:garage_id_touched?, false)
     |> assign(:address_results, [])
     |> assign(:address_unavailable?, false)
     |> assign(:garage_delete_target, nil)
     |> assign(:garage_in_use, nil)
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
     |> stream(:garages, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, refresh_garages(socket)}
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

  # --- garage drawer ---------------------------------------------------------

  @impl true
  def handle_event("open_garage", %{"garage_id" => id} = params, socket)
      when is_binary(id) and id != "" do
    case load_garage(socket, id) do
      nil -> {:noreply, socket}
      garage -> {:noreply, open_edit_garage(socket, garage, params["opener_id"])}
    end
  end

  def handle_event("open_garage", params, socket) do
    {:noreply, open_add_garage(socket, params["opener_id"])}
  end

  @impl true
  def handle_event("close_garage_drawer", _params, socket) do
    {:noreply, close_garage_drawer(socket)}
  end

  @impl true
  def handle_event("validate_garage", %{"garage" => params} = payload, socket) do
    target = payload["_target"]

    {params, id_touched?, derived_id} = default_garage_id(socket, params, target)
    params = fill_selected_address(socket, params, target)

    changeset =
      socket
      |> garage_base()
      |> Operations.change_garage(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:garage_id_touched?, id_touched?)
     |> assign(:garage_form, to_form(changeset, as: :garage))
     |> push_derived_garage_id(derived_id)}
  end

  def handle_event("validate_garage", _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_garage", %{"garage" => params}, socket) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
    params = submitted_garage_id(socket, params)

    result =
      case socket.assigns.garage_entity do
        nil -> Operations.create_garage(organization_id, actor, params)
        garage -> Operations.update_garage(organization_id, actor, garage.id, params)
      end

    case result do
      {:ok, garage} ->
        {:noreply,
         socket
         |> close_garage_drawer()
         |> refresh_garages()
         |> assign(:garage_notice, "#{garage.name} saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:garage_id_touched?, true)
         |> assign(:garage_form, to_form(changeset, as: :garage))
         |> push_event("focus_form_error", %{
           form_id: @garage_form_id,
           fallback_id: @garage_form_error_id
         })}

      {:error, :not_found} ->
        # The garage disappeared between opening the drawer and saving.
        {:noreply, socket |> close_garage_drawer() |> refresh_garages()}
    end
  end

  def handle_event("save_garage", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("live_select_change", %{"text" => text, "id" => id}, socket) do
    case Geocoding.autocomplete(text) do
      {:ok, results} ->
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

        {:noreply,
         socket
         |> assign(:address_results, results)
         |> assign(:address_unavailable?, false)}

      {:error, reason} ->
        Logger.error("Geocoding autocomplete failed: #{inspect(reason)}")
        send_update(LiveSelectComponent, id: id, options: [])

        {:noreply,
         socket
         |> assign(:address_results, [])
         |> assign(:address_unavailable?, true)}
    end
  end

  def handle_event("live_select_change", _params, socket), do: {:noreply, socket}

  # --- garage deletion -------------------------------------------------------

  @impl true
  def handle_event("delete_garage", %{"garage_id" => id}, socket) when is_binary(id) do
    case load_garage(socket, id) do
      nil ->
        {:noreply, socket}

      %Garage{vehicle_count: count} = garage when count > 0 ->
        {:noreply, assign(socket, :garage_in_use, garage)}

      garage ->
        {:noreply, assign(socket, :garage_delete_target, garage)}
    end
  end

  def handle_event("delete_garage", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_delete_garage", _params, socket) do
    {:noreply, assign(socket, :garage_delete_target, nil)}
  end

  @impl true
  def handle_event("dismiss_garage_in_use", _params, socket) do
    {:noreply, assign(socket, :garage_in_use, nil)}
  end

  @impl true
  def handle_event("confirm_delete_garage", _params, socket) do
    case socket.assigns.garage_delete_target do
      nil ->
        {:noreply, socket}

      garage ->
        delete_garage(socket, garage)
    end
  end

  defp delete_garage(socket, garage) do
    case Operations.delete_garage(socket.assigns.current_organization.id, garage.id) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> assign(:garage_delete_target, nil)
         |> close_garage_drawer()
         |> refresh_garages()
         |> assign(:garage_notice, "#{deleted.name} deleted.")}

      {:error, {:in_use, vehicles: _count}} ->
        {:noreply,
         socket
         |> assign(:garage_delete_target, nil)
         |> assign(:garage_in_use, garage)}

      {:error, :not_found} ->
        {:noreply, socket |> assign(:garage_delete_target, nil) |> refresh_garages()}
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
        Garages
        <:subtitle>Set where your vehicles start and end the day.</:subtitle>
        <:actions>
          <.button
            id="import-tods"
            variant="secondary"
            class="min-h-11"
            phx-click="open_tods_import"
            phx-value-opener_id="import-tods"
          >
            Import from TODS file
          </.button>
          <.button
            id="add-garage"
            variant={if(@garages_empty?, do: "secondary", else: "primary")}
            class="min-h-11"
            phx-click="open_garage"
            phx-value-opener_id="add-garage"
          >
            Add garage
          </.button>
        </:actions>
      </.header>

      <.scope_note organization_name={@current_organization.name} class="mt-2" />

      <p :if={@garage_notice} id="garage-notice" role="status" class="mt-2 text-sm text-success">
        {@garage_notice}
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
              <button
                id={"garage-name-#{garage.id}"}
                type="button"
                phx-click="open_garage"
                phx-value-garage_id={garage.id}
                phx-value-opener_id={"garage-name-#{garage.id}"}
                class="text-left font-semibold text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
              >
                {garage.name}
              </button>
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
          <.button
            id="add-garage-empty"
            class="min-h-11"
            phx-click="open_garage"
            phx-value-opener_id="add-garage-empty"
          >
            Add garage
          </.button>
        </:action>
      </.empty_state>

      <.tods_import_drawer
        open={@tods_import_open}
        kind={:garages}
        upload={@uploads.tods_file}
        preview={@tods_import_preview}
        filename={@tods_import_filename}
        parse_error={@tods_import_parse_error}
        stale?={@tods_import_stale?}
        return_focus_id={@tods_import_return_focus_id}
      />

      <.garage_drawer
        open={@garage_drawer_open}
        title={@garage_drawer_title}
        entity={@garage_entity}
        form={@garage_form}
        return_focus_id={@garage_drawer_return_focus_id}
        address_unavailable?={@address_unavailable?}
      />

      <.confirm_dialog
        :if={@garage_delete_target}
        id="garage-delete-confirm"
        open={true}
        title={"Delete #{@garage_delete_target.name}?"}
        confirm_label="Delete garage"
        pending_label="Deleting…"
        on_confirm="confirm_delete_garage"
        on_cancel="cancel_delete_garage"
        described_by="garage-delete-confirm-body"
        return_focus_id="garage-delete"
      >
        <p>This removes the garage from all service versions.</p>
      </.confirm_dialog>

      <.confirm_dialog
        :if={@garage_in_use}
        id="garage-in-use-dialog"
        open={true}
        title="Garage is in use"
        confirm_label="Delete garage"
        cancel_label="Close"
        pending_label="Deleting…"
        on_confirm="dismiss_garage_in_use"
        on_cancel="dismiss_garage_in_use"
        single_action={true}
        described_by="garage-in-use-dialog-body"
        return_focus_id="garage-delete"
      >
        <p>
          {@garage_in_use.name} has {@garage_in_use.vehicle_count} vehicles. Set a different garage for those vehicles before deleting it.
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
  attr :address_unavailable?, :boolean, default: false

  defp garage_drawer(assigns) do
    assigns =
      assigns
      |> assign(:form_id, @garage_form_id)
      |> assign(:form_error_id, @garage_form_error_id)

    ~H"""
    <.drawer
      id="garage-drawer"
      open={@open}
      on_close="close_garage_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
    >
      <div id="garage-drawer-content" phx-hook="FormErrorFocus">
        <p id="garage-drawer-description" class="mb-4 text-sm text-base-content/70">
          Choose a location for the start and end of the vehicle’s day.
        </p>

        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_garage"
          phx-submit="save_garage"
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

          <.input
            field={@form[:name]}
            type="text"
            label="Garage name"
            phx-debounce="blur"
            phx-blur="validate_garage"
          />

          <%!-- LiveView skips the `value` of a form input that already holds
          focus, so the derived ID would stay invisible for an operator who tabs
          out of the name field. This ignored host carries the hook that writes
          the pushed value into the ID field. --%>
          <span id="garage-id-default" phx-hook=".GarageIdDefault" phx-update="ignore" hidden></span>

          <.input
            field={@form[:garage_id]}
            type="text"
            label="Garage ID"
            help="Used when sharing operations data. This ID must not match a public stop."
            phx-debounce="blur"
            phx-blur="validate_garage"
          />

          <p :if={@entity} id="garage-id-change-hint" class="mb-2 text-sm text-base-content/70">
            Changing the ID keeps vehicle assignments. Systems that already imported the old ID will see a new garage.
          </p>

          <div class="fieldset mb-2">
            <label for="garage-address" class="label mb-1 text-base">
              Address search (optional)
            </label>
            <.live_component
              module={LiveSelectComponent}
              id="garage-address"
              field={@form[:address]}
              options={[]}
              debounce={300}
              update_min_len={3}
              placeholder="Search for an address"
              dropdown_class="bg-base-100 border border-base-300 shadow-lg mt-1 text-base-content"
              option_class="px-4 py-2.5 border-b border-base-300 last:border-b-0"
              active_option_class="bg-primary text-primary-content"
              available_option_class="hover:bg-base-200 cursor-pointer"
              text_input_class="input input-bordered w-full min-h-11"
            >
              <:option :let={option}>
                <span class="font-medium">{option.label}</span>
              </:option>
            </.live_component>
            <p
              :if={@address_unavailable?}
              id="garage-address-unavailable"
              class="mt-1.5 text-sm text-error"
            >
              Address search is unavailable. Enter coordinates.
            </p>
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:lat]}
              type="number"
              step="any"
              inputmode="decimal"
              label="Latitude"
              phx-debounce="blur"
              phx-blur="validate_garage"
            />
            <.input
              field={@form[:lon]}
              type="number"
              step="any"
              inputmode="decimal"
              label="Longitude"
              phx-debounce="blur"
              phx-blur="validate_garage"
            />
          </div>

          <p class="mt-1 text-sm text-base-content/70">
            Choose an address result or enter coordinates.
          </p>

          <div :if={@entity} class="mt-4">
            <.callout
              id="garage-assigned-vehicles"
              kind={if @entity.vehicle_count > 0, do: "warning", else: "info"}
              title={"#{@entity.vehicle_count} vehicles assigned"}
            >
              {if @entity.vehicle_count > 0,
                do: "Move these vehicles to another garage before deleting this garage.",
                else: "This garage has no assigned vehicles."}
            </.callout>
          </div>

          <div class="flex flex-wrap items-center gap-3 pt-3">
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">Save garage</.button>
            <.button type="button" variant="quiet" class="min-h-11" phx-click="close_garage_drawer">
              Cancel
            </.button>
            <.button
              :if={@entity}
              id="garage-delete"
              type="button"
              variant="danger"
              class="min-h-11"
              phx-click="delete_garage"
              phx-value-garage_id={@entity.id}
            >
              Delete garage
            </.button>
          </div>
        </.form>
      </div>
    </.drawer>

    <%!-- LiveView skips the `value` of a form input that already holds focus, and
    an operator who tabs out of the name field has focused the ID field by the
    time the derived ID arrives. This hook writes the pushed value into the field
    so the ID on screen is the ID that will be saved, and never overwrites an ID
    the operator has started typing. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GarageIdDefault">
      export default {
        mounted() {
          this.handleEvent("set_garage_id", ({value}) => {
            const field = document.getElementById("garage_garage_id");
            if (field && field.value === "") field.value = value;
          });
        }
      };
    </script>
    """
  end

  # --- drawer state ----------------------------------------------------------

  defp garage_form(garage, attrs) do
    garage
    |> Operations.change_garage(attrs)
    |> to_form(as: :garage)
  end

  defp garage_base(socket), do: socket.assigns.garage_entity || %Garage{}

  defp open_add_garage(socket, opener_id) do
    socket
    |> assign(:garage_entity, nil)
    |> assign(:garage_form, garage_form(%Garage{}, %{}))
    |> assign(:garage_drawer_title, "Add garage")
    |> assign(:garage_id_touched?, false)
    |> assign(:address_results, [])
    |> assign(:address_unavailable?, false)
    |> assign(:garage_drawer_return_focus_id, opener_id)
    |> assign(:garage_notice, nil)
    |> assign(:garage_drawer_open, true)
  end

  defp open_edit_garage(socket, garage, opener_id) do
    socket
    |> assign(:garage_entity, garage)
    |> assign(:garage_form, garage_form(garage, %{}))
    |> assign(:garage_drawer_title, "Edit garage")
    # Generation is always off for a saved garage.
    |> assign(:garage_id_touched?, true)
    |> assign(:address_results, [])
    |> assign(:address_unavailable?, false)
    |> assign(:garage_drawer_return_focus_id, opener_id)
    |> assign(:garage_notice, nil)
    |> assign(:garage_drawer_open, true)
  end

  # The opener id survives the close so the shipped OverlayDialog hook can still
  # read it while returning focus.
  defp close_garage_drawer(socket) do
    socket
    |> assign(:garage_drawer_open, false)
    |> assign(:garage_entity, nil)
    |> assign(:garage_id_touched?, false)
    |> assign(:address_results, [])
    |> assign(:address_unavailable?, false)
  end

  # On add, the ID defaults from the name only until the user edits the ID field.
  # Typing or clearing that field always counts as editing. A submitted save also
  # counts, so a rejected save can never have its ID overwritten by a later name
  # change.
  defp default_garage_id(socket, params, target) do
    id_touched? = socket.assigns.garage_id_touched? or garage_id_target?(target)

    if is_nil(socket.assigns.garage_entity) and not id_touched? do
      derived_id = Operations.default_garage_id(params["name"])
      {Map.put(params, @garage_id_field, derived_id), id_touched?, derived_id}
    else
      {params, id_touched?, nil}
    end
  end

  # LiveView never patches the `value` of the form input that currently holds
  # focus, and the operator's Tab puts focus on the ID field before this reply
  # arrives, so a derived ID would stay invisible. The drawer's hook writes the
  # derived value into the field instead.
  defp push_derived_garage_id(socket, nil), do: socket

  defp push_derived_garage_id(socket, ""), do: socket

  defp push_derived_garage_id(socket, derived_id),
    do: push_event(socket, "set_garage_id", %{value: derived_id})

  # An operator can submit straight from the name field, before the derived
  # value reached the browser, so the same rule applies to the submitted ID.
  defp submitted_garage_id(%{assigns: %{garage_entity: nil}} = socket, params) do
    if socket.assigns.garage_id_touched? or present?(params[@garage_id_field]) do
      params
    else
      Map.put(params, @garage_id_field, Operations.default_garage_id(params["name"]))
    end
  end

  defp submitted_garage_id(_socket, params), do: params

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp garage_id_target?(@garage_id_target), do: true
  defp garage_id_target?(_target), do: false

  # A chosen address result fills the coordinates. The LiveSelect writes its
  # selection into the form's hidden `garage[address]` input, whose change names
  # that field as `_target`, so the submitted value is matched against the cached
  # results instead of trusted. The coordinates stay editable because a later
  # lat/lon change does not name the address field.
  defp fill_selected_address(socket, params, @garage_address_target) do
    case find_address_result(socket.assigns.address_results, params[@garage_address_field]) do
      nil ->
        params

      result ->
        params
        |> Map.put(@garage_address_field, result.formatted_address)
        |> Map.put("lat", result.lat)
        |> Map.put("lon", result.lon)
    end
  end

  defp fill_selected_address(_socket, params, _target), do: params

  defp find_address_result(results, address) when is_binary(address) and address != "" do
    Enum.find(results, &(&1.formatted_address == address))
  end

  defp find_address_result(_results, _address), do: nil

  defp load_garage(socket, id) when is_binary(id) do
    socket.assigns.current_organization.id
    |> Operations.list_garages()
    |> Enum.find(&(&1.id == id))
  end

  defp load_garage(_socket, _id), do: nil

  defp refresh_garages(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    garages = Operations.list_garages(organization_id)
    conflicts = Operations.garage_stop_id_conflicts(organization_id, gtfs_version_id, garages)

    socket
    |> assign(:garage_count, length(garages))
    |> assign(:garages_empty?, garages == [])
    |> assign(:assigned_vehicle_count, Enum.sum(Enum.map(garages, & &1.vehicle_count)))
    |> assign(:garage_conflicts, conflicts)
    |> stream(:garages, garages, reset: true)
  end

  # A failed save is the only state that earns the view-level banner. Validation
  # on blur marks its own fields and must not shout about a save never attempted.
  defp save_failed?(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action}, errors: errors})
       when action in [:update, :insert] and errors != [],
       do: true

  defp save_failed?(_form), do: false

  # --- TODS import state ------------------------------------------------------

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
      {:ok, content} -> Tods.parse(:garages, file, content)
      {:error, _reason} -> {:error, "#{file} could not be read."}
    end
  end

  defp apply_reviewed_tods_import(socket, parsed, preview) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    case Operations.apply_tods_import(organization_id, actor, parsed, preview) do
      {:ok, %{added: added, updated: updated}} ->
        {:noreply,
         socket
         |> reset_tods_import_review()
         |> assign(:tods_import_open, false)
         |> refresh_garages()
         |> assign(:garage_notice, "Garages imported: #{added} added, #{updated} updated.")}

      # The context refuses a plan whose recomputed rows differ and hands back the
      # refreshed preview, so the drawer keeps the reviewed state visible, swaps in
      # the new counts and moves focus to the message.
      {:error, {_reason, refreshed_preview}} ->
        {:noreply,
         socket
         |> assign(:tods_import_preview, refreshed_preview)
         |> assign(:tods_import_stale?, true)
         |> push_event("focus_scoped_target", %{id: "tods-import-error"})}
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

  defp garage_has_address?(garage), do: garage.address not in [nil, ""]

  defp garage_location(garage) do
    if garage_has_address?(garage), do: garage.address, else: garage_coordinates(garage)
  end

  defp garage_coordinates(garage) do
    "#{Decimal.to_string(garage.lat)}, #{Decimal.to_string(garage.lon)}"
  end
end
