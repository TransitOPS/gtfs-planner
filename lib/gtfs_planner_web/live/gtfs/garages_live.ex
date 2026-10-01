defmodule GtfsPlannerWeb.Gtfs.GaragesLive do
  @moduledoc """
  LiveView for the organization's garages: the list, the create/edit drawer and
  the guarded delete flow.

  Garages belong to the organization and ignore GTFS versions: the version in
  the URL is navigation context and selects which `stops.stop_id` values the
  conflict notice compares against. Access is authorized at mount through
  `EnsureRole`, following the other GTFS pages — there is no view-only GTFS role,
  and the context enforces tenancy on every call.

  The drawer reuses the shared `drawer/1`, `input/1` and `confirm_dialog/1`
  components in the design system's planner chrome, and the gallery's `LiveSelect`
  autocomplete pattern. `Garage.changeset/2` owns validation, so a rejected submit returns
  focus to the first invalid field through the scoped `FormErrorFocus` hook.

  A delete is refused while any vehicle, block attribute or route operating
  setting references the garage: the page reads
  `Operations.garage_in_use_counts/2` before opening the confirmation and
  `Operations.delete_garage/3` still attempts the write, naming the same counts
  when a reference appears in between. A garage nothing references is deleted
  with its entered driving times, whose refs are the garage UUID.

  `garage_id` is a correctable external ID: creation derives it from the name
  until the user edits the ID field (tracked from the form event's `_target`),
  and a saved garage's ID is never regenerated from a name change.

  "Import garages" opens the shared `tods_import_drawer/1`: the chosen
  file is parsed by `Tods` and previewed through `Operations.preview_tods_import/2`,
  and only the reviewed plan may be applied. The review describes exactly one
  upload, so closing the drawer, cancelling the upload or choosing another file
  discards it rather than leaving a plan that no longer matches the screen.
  """

  require Logger

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.OperationsComponents,
    only: [in_use_message: 2, in_use_summary: 1, tods_import_drawer: 1, tods_review_current?: 2]

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      back_link: 1,
      drawer_footer: 1,
      drawer_scroll: 1,
      first_use: 1,
      form_section: 1,
      message: 1,
      scope_line: 1
    ]

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

  @permission_error "You no longer have permission to edit garages. " <>
                      "Ask an organization administrator to restore your access."

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
     |> assign(:garage_counts, nil)
     |> assign(:garage_form, garage_form(%Garage{}, %{}))
     |> assign(:garage_drawer_title, "Create garage")
     |> assign(:garage_drawer_return_focus_id, nil)
     |> assign(:garage_id_touched?, false)
     |> assign(:address_results, [])
     |> assign(:address_search_generation, 0)
     |> assign(:address_search_text, "")
     |> assign(:address_search_state, nil)
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
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/settings/garages")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/settings/garages")}
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

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:garage_form, garage_form(garage_base(socket), params))
         |> put_flash(:error, @permission_error)}
    end
  end

  def handle_event("save_garage", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("live_select_change", %{"text" => text, "id" => "garage-address"}, socket) do
    {:noreply, search_address(socket, text)}
  end

  def handle_event("live_select_change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_address_search", _params, socket) do
    {:noreply, search_address(socket, socket.assigns.address_search_text)}
  end

  # --- garage deletion -------------------------------------------------------

  @impl true
  def handle_event("delete_garage", %{"garage_id" => id}, socket) when is_binary(id) do
    case load_garage(socket, id) do
      nil ->
        {:noreply, socket}

      garage ->
        counts =
          Operations.garage_in_use_counts(socket.assigns.current_organization.id, garage.id)

        if Operations.in_use?(counts) do
          {:noreply, show_garage_in_use(socket, garage, counts)}
        else
          {:noreply, assign(socket, :garage_delete_target, garage)}
        end
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

  @impl true
  def handle_async(:address_search, {:ok, {generation, result}}, socket) do
    if socket.assigns.garage_drawer_open and
         generation == socket.assigns.address_search_generation do
      case result do
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

          send_update(LiveSelectComponent, id: "garage-address", options: options)

          {:noreply,
           socket
           |> assign(:address_results, results)
           |> assign(:address_search_state, if(results == [], do: :empty, else: :results))}

        {:error, reason} ->
          Logger.error("Geocoding autocomplete failed: #{inspect(reason)}")
          send_update(LiveSelectComponent, id: "garage-address", options: [])

          {:noreply,
           socket
           |> assign(:address_results, [])
           |> assign(:address_search_state, :failed)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:address_search, {:exit, reason}, socket) do
    Logger.error("Geocoding autocomplete task exited: #{inspect(reason)}")

    # An exit has no generation payload; a closed and reopened drawer is no
    # longer searching even if LiveView still holds the earlier task reference.
    {:noreply,
     if(
       socket.assigns.garage_drawer_open and
         socket.assigns.address_search_state == :searching,
       do: assign(socket, :address_search_state, :failed),
       else: socket
     )}
  end

  defp search_address(socket, text) do
    generation = socket.assigns.address_search_generation + 1
    send_update(LiveSelectComponent, id: "garage-address", options: [])

    socket =
      socket
      |> assign(:address_search_generation, generation)
      |> assign(:address_search_text, text)
      |> assign(:address_results, [])
      |> assign(:address_search_state, :searching)

    start_async(socket, :address_search, fn -> {generation, Geocoding.autocomplete(text)} end)
  end

  defp delete_garage(socket, garage) do
    case Operations.delete_garage(
           socket.assigns.current_organization.id,
           socket.assigns.current_user,
           garage.id
         ) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> assign(:garage_delete_target, nil)
         |> close_garage_drawer()
         |> refresh_garages()
         |> assign(:garage_notice, "#{deleted.name} deleted.")}

      {:error, {:in_use, counts}} ->
        {:noreply,
         socket
         |> assign(:garage_delete_target, nil)
         |> show_garage_in_use(garage, counts)}

      {:error, :not_found} ->
        {:noreply, socket |> assign(:garage_delete_target, nil) |> refresh_garages()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, @permission_error)}
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
      <div id="garages-page" class="ds-page">
        <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
          Settings
        </.back_link>

        <.header>
          Garages
          <:subtitle>
            Set where vehicles start and end the day: depots, yards and operating bases. Blocks use
            these locations to work out pull-out and pull-in travel.
            <.scope_line id="garages-scope" icon="hero-square-3-stack-3d">
              Applies to every service version at {@current_organization.name}. Switching versions
              doesn't change these garages, only which stops the ID check compares against.
            </.scope_line>
          </:subtitle>
          <%!-- With no garages yet, the first-use panel carries both actions. --%>
          <:actions :if={!@garages_empty?}>
            <.button
              id="import-tods"
              variant="secondary"
              class="min-h-11"
              phx-click="open_tods_import"
              phx-value-opener_id="import-tods"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Import garages
            </.button>
            <.button
              id="add-garage"
              class="min-h-11"
              phx-click="open_garage"
              phx-value-opener_id="add-garage"
            >
              <.icon name="hero-plus" class="size-4" /> Create garage
            </.button>
          </:actions>
        </.header>

        <div class="grid gap-4">
          <.message :if={@garage_notice} id="garage-notice" kind="success" title={@garage_notice} />

          <.garage_conflicts
            :if={@garage_conflicts != []}
            conflicts={@garage_conflicts}
            version={@current_gtfs_version}
          />

          <.garages_table
            :if={!@garages_empty?}
            rows={@streams.garages}
            garage_count={@garage_count}
            vehicle_count={@assigned_vehicle_count}
            version={@current_gtfs_version}
          />

          <.first_use
            :if={@garages_empty?}
            id="garages-first-use-empty"
            title="Add your first garage"
            icon="hero-building-office"
          >
            A garage is any depot, yard or base where vehicles start and end the day. Add one so
            blocks can work out pull-out and pull-in travel.
            <:action>
              <div class="flex flex-wrap justify-center gap-3">
                <.button
                  id="add-garage-empty"
                  class="min-h-11"
                  phx-click="open_garage"
                  phx-value-opener_id="add-garage-empty"
                >
                  <.icon name="hero-plus" class="size-4" /> Create garage
                </.button>
                <.button
                  id="import-tods"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="open_tods_import"
                  phx-value-opener_id="import-tods"
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Import garages
                </.button>
              </div>
              <p class="mt-4 text-[13px] text-muted">
                Already keep garages in your operations system? Import them from a TODS file
                instead of typing each one.
              </p>
            </:action>
          </.first_use>
        </div>

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
          counts={@garage_counts}
          form={@garage_form}
          return_focus_id={@garage_drawer_return_focus_id}
          address_search_state={@address_search_state}
        />

        <.confirm_dialog
          :if={@garage_delete_target}
          id="garage-delete-confirm"
          chrome="planner"
          open={true}
          title={"Delete #{@garage_delete_target.name}?"}
          confirm_label="Delete garage"
          cancel_label="Keep garage"
          pending_label="Deleting…"
          on_confirm="confirm_delete_garage"
          on_cancel="cancel_delete_garage"
          described_by="garage-delete-confirm-body"
          return_focus_id="garage-delete"
        >
          <p>This removes the garage from every service version. You can't undo it.</p>
        </.confirm_dialog>

        <.confirm_dialog
          :if={@garage_in_use}
          id="garage-in-use-dialog"
          chrome="planner"
          open={true}
          title={"Can't delete #{@garage_in_use.garage.name}"}
          confirm_label="Close"
          cancel_label="Close"
          pending_label="Closing…"
          on_confirm="dismiss_garage_in_use"
          on_cancel="dismiss_garage_in_use"
          single_action={true}
          described_by="garage-in-use-dialog-body"
          return_focus_id="garage-delete"
        >
          <p>{in_use_message(@garage_in_use.garage.name, @garage_in_use.counts)}</p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # A garage ID that equals a stop ID would make the operations export change that
  # stop, so the export refuses it. The message leads with that consequence, then
  # names each garage and the stop it clashes with. Fixing one is the same edit as
  # any other: open the garage from the list and change its ID.
  attr :conflicts, :list, required: true
  attr :version, :any, required: true

  defp garage_conflicts(assigns) do
    ~H"""
    <.message id="garage-conflicts" kind="warning" title={conflict_title(length(@conflicts))}>
      <p>
        Exports list garages next to public stops by ID, so a shared ID would change that stop. Give {conflict_target(
          length(@conflicts)
        )} a different ID, then export again.
      </p>
      <ul class="mt-3 grid gap-2">
        <li :for={conflict <- @conflicts} class="rounded-control bg-white px-3 py-2 text-default">
          <strong class="font-[650] text-strong">{conflict.garage_name}</strong>
          uses ID <code class="font-mono text-[13px]">{conflict.garage_id}</code>,
          the same as the stop <strong class="font-[650] text-strong">{conflict.stop_name}</strong>.
        </li>
      </ul>
      <p class="mt-3 text-[13px]">
        Checked against stops in {@version.name}. Switch versions to check another.
      </p>
    </.message>
    """
  end

  # Garages are few and read by name, so the list is one table: the garage and its
  # ID, where it is, and the vehicles assigned. Each name opens the row's editor.
  # Below `md` a row is a stacked record rather than a horizontally scrolling table.
  attr :rows, :any, required: true, doc: "the `:garages` stream"
  attr :garage_count, :integer, required: true
  attr :vehicle_count, :integer, required: true
  attr :version, :any, required: true

  defp garages_table(assigns) do
    ~H"""
    <section
      id="garages-list"
      aria-label="Garages"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex min-h-[52px] items-center border-b border-subtle px-4 py-1 md:px-5">
        <p id="garages-status" class="text-[13px] font-[650] tabular-nums text-strong">
          {count_label(@garage_count, "garage")} · {count_label(@vehicle_count, "vehicle")} assigned
        </p>
      </div>

      <table id="garages-table" class="w-full border-collapse text-left text-sm">
        <caption class="sr-only">
          Garages
        </caption>
        <thead class="max-md:hidden">
          <tr class="bg-canvas">
            <th scope="col" class={[head_class(), "w-[34%] pl-5"]}>Garage</th>
            <th scope="col" class={head_class()}>Location</th>
            <th scope="col" class={[head_class(), "w-[200px] pr-5 text-right"]}>Vehicles</th>
          </tr>
        </thead>
        <tbody id="garages" phx-update="stream">
          <tr
            :for={{id, garage} <- @rows}
            id={id}
            class="border-t border-subtle align-top hover:bg-canvas max-md:block max-md:px-4 max-md:py-3"
          >
            <td data-label="Garage" class="py-2 pl-5 pr-4 max-md:block max-md:p-0">
              <button
                id={"garage-name-#{garage.id}"}
                type="button"
                phx-click="open_garage"
                phx-value-garage_id={garage.id}
                phx-value-opener_id={"garage-name-#{garage.id}"}
                class={[
                  "grid min-h-11 min-w-0 content-center rounded-control text-left [overflow-wrap:anywhere]",
                  "group",
                  focus_class()
                ]}
              >
                <span class="text-[15px] font-[650] text-action underline-offset-4 group-hover:text-action-hover group-hover:underline">
                  {garage.name}
                </span>
                <span class="font-mono text-[13px] text-muted">{garage.garage_id}</span>
              </button>
            </td>
            <td data-label="Location" class="px-4 py-3 max-md:mt-1 max-md:block max-md:p-0">
              <p class="text-default [overflow-wrap:anywhere]">{garage_location(garage)}</p>
              <p :if={garage_has_address?(garage)} class="text-[13px] tabular-nums text-muted">
                {garage_coordinates(garage)}
              </p>
            </td>
            <td
              data-label="Vehicles"
              class="py-2 pl-4 pr-5 text-right max-md:mt-1 max-md:block max-md:p-0 max-md:text-left"
            >
              <.link
                :if={garage.vehicle_count > 0}
                navigate={~p"/gtfs/#{@version.id}/settings/fleet?garage=#{garage.id}"}
                class="inline-flex min-h-11 items-center text-sm font-[650] tabular-nums text-action underline-offset-4 hover:text-action-hover hover:underline"
              >
                {count_label(garage.vehicle_count, "vehicle")}
              </.link>
              <p :if={garage.vehicle_count == 0} class="py-3 text-muted">None yet</p>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp head_class, do: "px-4 py-2.5 text-left text-[13px] font-[650] text-default"

  defp focus_class,
    do: "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

  attr :open, :boolean, required: true
  attr :title, :string, required: true
  attr :entity, :any, default: nil
  attr :counts, :map, default: nil
  attr :form, :any, required: true
  attr :return_focus_id, :string, default: nil
  attr :address_search_state, :atom, default: nil

  defp garage_drawer(assigns) do
    assigns =
      assigns
      |> assign(:form_id, @garage_form_id)
      |> assign(:form_error_id, @garage_form_error_id)

    ~H"""
    <.drawer
      id="garage-drawer"
      chrome="planner"
      open={@open}
      on_close="close_garage_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[520px]"
    >
      <:lede>
        <span id="garage-drawer-scope">{drawer_scope(@entity)}</span>
      </:lede>

      <div id="garage-drawer-content" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_garage"
          phx-submit="save_garage"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.message
              :if={save_failed?(@form)}
              id={@form_error_id}
              kind="error"
              title="Garage not saved"
              tabindex="-1"
            >
              Fix the fields marked below, then save again.
            </.message>

            <%!-- Having vehicles is normal, so this is a fact, not a warning. The
            delete rule it states is enforced when Delete garage is pressed. --%>
            <p
              :if={@entity}
              id="garage-assigned-vehicles"
              class="flex items-start gap-3 rounded-control bg-canvas px-4 py-3 text-sm text-default"
            >
              <.icon name="hero-truck" class="mt-0.5 size-5 shrink-0 text-muted" />
              <span class="min-w-0">
                <strong class="font-[650] text-strong">{use_title(@counts)}</strong>
                {use_body(@counts)}
              </span>
            </p>

            <.input
              field={@form[:name]}
              type="text"
              label="Garage name"
              help="The name your team uses, like Newport Operations Base."
              autocomplete="off"
              phx-debounce="blur"
              phx-blur="validate_garage"
            />

            <div class="grid gap-1.5">
              <%!-- LiveView skips the `value` of a form input that already holds
              focus, so the derived ID would stay invisible for an operator who tabs
              out of the name field. This ignored host carries the hook that writes
              the pushed value into the ID field. --%>
              <span id="garage-id-default" phx-hook=".GarageIdDefault" phx-update="ignore" hidden>
              </span>

              <.input
                field={@form[:garage_id]}
                type="text"
                class="w-full input input-lg font-mono"
                label="Garage ID"
                help={garage_id_help(@entity)}
                autocomplete="off"
                spellcheck="false"
                phx-debounce="blur"
                phx-blur="validate_garage"
              />

              <p
                :if={@entity}
                id="garage-id-change-hint"
                class="flex items-start gap-1.5 text-[13px] text-muted"
              >
                <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
                <span>
                  Changing the ID keeps vehicle assignments. Systems that already imported the old ID will see a new garage.
                </span>
              </p>
            </div>

            <.form_section title="Location">
              <div class="fieldset">
                <label for="garage_address_text_input">
                  <span class="label">
                    Find an address <span class="font-normal text-muted">(optional)</span>
                  </span>
                </label>
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="pointer-events-none absolute left-3 top-1/2 z-10 size-4 -translate-y-1/2 text-muted"
                  />
                  <.live_component
                    module={LiveSelectComponent}
                    id="garage-address"
                    field={@form[:address]}
                    options={[]}
                    debounce={300}
                    update_min_len={3}
                    placeholder="Start typing a street address"
                    dropdown_class="absolute inset-x-0 top-full z-50 mt-1 max-h-60 overflow-auto rounded-card border border-subtle bg-white p-1 text-strong shadow-float"
                    option_class="flex min-h-11 items-center gap-2 rounded-control px-3 py-1.5 text-sm"
                    active_option_class="bg-selection"
                    available_option_class="cursor-pointer hover:bg-canvas"
                    text_input_class="input w-full pl-9 pr-6"
                    text_input_selected_class="text-strong"
                  >
                    <:option :let={option}>
                      <.icon name="hero-map-pin" class="size-4 shrink-0 text-muted" />
                      <span class="min-w-0">{option.label}</span>
                    </:option>
                  </.live_component>
                </div>
                <p>Choose a result to fill in the coordinates below.</p>
                <div
                  :if={@address_search_state in [:searching, :empty, :failed]}
                  id="garage-address-search-status"
                  role="status"
                  aria-live="polite"
                  class={[
                    "text-[13px]",
                    if(@address_search_state == :failed, do: "text-error", else: "text-muted")
                  ]}
                >
                  <%= case @address_search_state do %>
                    <% :searching -> %>
                      Searching addresses…
                    <% :empty -> %>
                      No matching addresses
                    <% :failed -> %>
                      <span>Address search is unavailable.</span>
                      <.button
                        id="garage-address-retry"
                        type="button"
                        variant="secondary"
                        class="ml-2 min-h-11"
                        phx-click="retry_address_search"
                      >
                        Retry search
                      </.button>
                    <% _ -> %>
                  <% end %>
                </div>
              </div>

              <div class="grid grid-cols-2 items-start gap-3">
                <.input
                  field={@form[:lat]}
                  type="number"
                  step="any"
                  inputmode="decimal"
                  label="Latitude"
                  help="Decimal degrees, like 44.6114."
                  autocomplete="off"
                  phx-debounce="blur"
                  phx-blur="validate_garage"
                />
                <.input
                  field={@form[:lon]}
                  type="number"
                  step="any"
                  inputmode="decimal"
                  label="Longitude"
                  help="Negative in the western hemisphere, like -124.0489."
                  autocomplete="off"
                  phx-debounce="blur"
                  phx-blur="validate_garage"
                />
              </div>
            </.form_section>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              :if={@entity}
              id="garage-delete"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 text-error-fg hover:bg-error-bg"
              phx-click="delete_garage"
              phx-value-garage_id={@entity.id}
            >
              <.icon name="hero-trash" class="size-4" /> Delete garage
            </.button>
            <.button
              id="garage-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_garage_drawer"
            >
              Cancel
            </.button>
            <.button id="garage-save" type="submit" class="min-h-11" phx-disable-with="Saving…">
              {if @entity, do: "Save changes", else: "Create garage"}
            </.button>
          </.drawer_footer>
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
    |> assign(:garage_drawer_title, "Create garage")
    |> assign(:garage_id_touched?, false)
    |> assign(:address_results, [])
    |> assign(:address_search_generation, socket.assigns.address_search_generation + 1)
    |> assign(:address_search_text, "")
    |> assign(:address_search_state, nil)
    |> assign(:garage_drawer_return_focus_id, opener_id)
    |> assign(:garage_notice, nil)
    |> assign(:garage_drawer_open, true)
  end

  defp open_edit_garage(socket, garage, opener_id) do
    socket
    |> assign(:garage_entity, garage)
    |> assign(
      :garage_counts,
      Operations.garage_in_use_counts(socket.assigns.current_organization.id, garage.id)
    )
    |> assign(:garage_form, garage_form(garage, %{}))
    |> assign(:garage_drawer_title, "Edit garage")
    # Generation is always off for a saved garage.
    |> assign(:garage_id_touched?, true)
    |> assign(:address_results, [])
    |> assign(:address_search_generation, socket.assigns.address_search_generation + 1)
    |> assign(:address_search_text, "")
    |> assign(:address_search_state, nil)
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
    |> assign(:address_search_generation, socket.assigns.address_search_generation + 1)
    |> assign(:address_search_text, "")
    |> assign(:address_search_state, nil)
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

  defp garage_has_address?(garage), do: garage.address not in [nil, ""]

  defp garage_location(garage) do
    if garage_has_address?(garage), do: garage.address, else: garage_coordinates(garage)
  end

  defp garage_coordinates(garage) do
    "#{Decimal.to_string(garage.lat)}, #{Decimal.to_string(garage.lon)}"
  end

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  defp conflict_title(1), do: "Operations export is blocked: 1 garage ID matches a stop"
  defp conflict_title(count), do: "Operations export is blocked: #{count} garage IDs match stops"

  defp conflict_target(1), do: "this garage"
  defp conflict_target(_count), do: "each garage below"

  defp drawer_scope(nil), do: "Shared across all versions"
  defp drawer_scope(garage), do: "#{garage.name} · shared across all versions"

  # A saved garage's ID is never regenerated, so only the create form says it was
  # filled in from the name.
  defp garage_id_help(nil) do
    "Filled in from the name. Exports and imports use it to recognize this garage. It can't match a stop ID."
  end

  defp garage_id_help(_garage) do
    "Exports and imports use it to recognize this garage. It can't match a stop ID."
  end

  # The drawer states the same references the delete is refused on, read when
  # the drawer opens and again when a delete is refused.
  defp use_title(counts) do
    case in_use_summary(counts) do
      nil -> "Nothing uses this garage,"
      summary -> "Used by #{summary}."
    end
  end

  defp use_body(counts) do
    if Operations.in_use?(counts),
      do: "To delete it, first change those.",
      else: "so you can delete it without moving anything."
  end

  # The refusal's counts are current; the counts the drawer opened with may not be.
  defp show_garage_in_use(socket, garage, counts) do
    socket
    |> assign(:garage_counts, counts)
    |> assign(:garage_in_use, %{garage: garage, counts: counts})
  end
end
