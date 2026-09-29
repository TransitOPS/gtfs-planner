defmodule GtfsPlannerWeb.Gtfs.ExportDefaultsLive do
  @moduledoc """
  Settings › Export defaults: the organization-wide settings an export reads.

  Two settings live here, and both come from the reference's export line: whether
  a full export also writes the flex file, and which file the agency's realtime
  vendor reads. They apply to every version of the organization, so the version
  in the URL is navigation context and a version switch keeps this page, as
  Garages and Fleet do.

  The page saves once. A keystroke re-reads the switch's consequence and the note
  for the chosen realtime answer from the draft, and Save writes both settings
  through `ExportDefaults.update/2`, whose changeset casts the two settings only —
  a submitted organization ID is ignored rather than written. The Flex list reads
  the same row for its export-state line, so the two surfaces cannot disagree
  about whether exports carry flex.

  The export defaults the catalog still promises — ID formats and stop times
  between timepoints — are named in a note at the foot of the page instead of
  being offered as controls that cannot work yet.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, scope_line: 1]

  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.FlexComponents
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Export defaults")
     |> assign(:defaults, nil)
     |> assign(:form, nil)
     |> assign(:include_flex, true)
     |> assign(:realtime_note, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    defaults = ExportDefaults.get(socket.assigns.current_organization.id)

    {:noreply,
     socket
     |> assign(:defaults, defaults)
     |> assign_form(ExportDefault.changeset(defaults, %{}))}
  end

  @impl true
  def handle_event("validate", %{"export_default" => params}, socket) do
    changeset = ExportDefault.changeset(socket.assigns.defaults, params)

    {:noreply, assign_form(socket, changeset, :validate)}
  end

  @impl true
  def handle_event("save", %{"export_default" => params}, socket) do
    case ExportDefaults.update(socket.assigns.current_organization.id, params) do
      {:ok, defaults} ->
        {:noreply,
         socket
         |> assign(:defaults, defaults)
         |> assign_form(ExportDefault.changeset(defaults, %{}))
         |> put_flash(:info, "Export defaults saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        # The select and the switch carry one value each, so a rejected save is a
        # forged or stale request; the draft stays visible with its error.
        {:noreply,
         socket
         |> assign_form(changeset, :insert)
         |> put_flash(:error, "Nothing was saved. Check the highlighted field.")}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # A version switch keeps this page, because the settings here apply to every
  # version; only another published version of this organization navigates.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: section_path(version_id))}
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
      {:noreply, push_navigate(socket, to: section_path(version_id))}
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
      <div id="export-defaults-page" class="ds-page">
        <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
          Settings
        </.back_link>

        <.header>
          Export defaults
          <:subtitle>
            All versions · Choose how future exports are written.
            <.scope_line id="export-defaults-scope" icon="hero-square-3-stack-3d">
              Shared across all service versions for {@current_organization.name}.
            </.scope_line>
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="export-defaults-form"
          novalidate
          phx-change="validate"
          phx-submit="save"
          class="mt-6 max-w-2xl"
        >
          <fieldset class="border-t border-base-300 pt-5 first:mt-0 first:border-t-0 first:pt-0">
            <legend class="pr-4 text-base font-semibold text-base-content">Flex services</legend>

            <div class="mt-4">
              <.input
                field={@form[:include_flex]}
                type="checkbox"
                id="flex-switch"
                class="toggle toggle-primary"
                label="Include flex services in exports"
              />

              <p id="flex-switch-consequence" class="mt-2 text-sm text-base-content/70">
                {switch_consequence(@include_flex)}
              </p>
            </div>
          </fieldset>

          <fieldset class="mt-6 border-t border-base-300 pt-5">
            <legend class="pr-4 text-base font-semibold text-base-content">Realtime</legend>

            <%!-- The question is the reference's own wording and wraps on a narrow
          screen: `input/1`'s own label renders in daisyUI's `label` span, which
          does not wrap, so the label is written here instead. --%>
            <label for="realtime-source" class="mt-4 block text-sm font-semibold text-base-content">
              Which file does your realtime vendor read?
            </label>

            <div class="mt-1 max-w-xs">
              <.input
                field={@form[:realtime_source]}
                type="select"
                id="realtime-source"
                options={FlexComponents.realtime_options()}
              />
            </div>

            <FlexComponents.realtime_note_card :if={@realtime_note} note={@realtime_note} />

            <p class="mt-1 text-[13px] text-muted">
              One answer for your agency. Every version uses it, and it applies to every route.
            </p>
          </fieldset>

          <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">
              Save changes
            </.button>
          </div>
        </.form>

        <p
          id="export-defaults-more"
          class="mt-8 max-w-2xl border-t border-base-300 pt-4 text-sm text-base-content/70"
        >
          More export defaults are coming. ID formats and stop times between timepoints will join this
          page.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  # The switch's consequence in the reference's words: what a full export writes
  # with flex on, and what riders lose with it off.
  defp switch_consequence(true) do
    "Exports also write a flex file: your fixed routes plus flex, built and published with your main feed. Apps that show flex load it instead of the main feed, which stays as it is for Google Maps."
  end

  defp switch_consequence(false) do
    "Exports leave flex out. Riders won’t see these services in trip planners until flex is turned on."
  end

  # The form, the switch's consequence and the realtime note always move
  # together, so a keystroke cannot show a control whose explanation describes
  # another value. Both are read from the cast changeset rather than the form's
  # own field values, which hold the submitted strings during a validate round
  # trip. `action: :validate` marks the round trip as a keystroke, so an error
  # appears only beside a touched field.
  defp assign_form(socket, %Ecto.Changeset{} = changeset, action \\ nil) do
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset

    socket
    |> assign(:form, to_form(changeset, as: :export_default))
    |> assign(:include_flex, Ecto.Changeset.get_field(changeset, :include_flex))
    |> assign(
      :realtime_note,
      FlexComponents.realtime_note(Ecto.Changeset.get_field(changeset, :realtime_source), nil)
    )
  end

  defp section_path(version_id), do: "/gtfs/#{version_id}/settings/export-defaults"
end
