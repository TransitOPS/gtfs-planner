defmodule GtfsPlannerWeb.Gtfs.ExportLive do
  @moduledoc """
  LiveView for exporting GTFS data.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export.MissingTimes
  alias GtfsPlanner.Gtfs.Export.Runner, as: ExportRunner
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ProductSurfaces
  alias Phoenix.LiveView.AsyncResult

  import GtfsPlannerWeb.Gtfs.ExportComponents,
    only: [
      check_panel: 1,
      closures_omitted: 1,
      contents: 1,
      guide: 1,
      operations_note: 1,
      recent_checks: 1,
      run_status: 1,
      type_options: 1
    ]

  import GtfsPlannerWeb.ResultComponents, only: [result_section: 1]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The URL is the single source of truth for the selected export type: only
  # these query values are accepted, and `export_type_from_param/1` maps them
  # onto the atoms `ExportRuns` accepts.
  @export_type_params ~w(full pathways operations)

  @export_busy_message "Another export is running. Try again when it finishes."
  @validation_busy_message "Another validation is running. Try again when it finishes."
  @validation_permission_message "You no longer have permission to check this feed. " <>
                                   "Ask an organization administrator to restore your access."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Export feed")
     |> assign(:user_roles, user_roles)
     |> assign(:export_type, :full)
     |> assign(:export_form, export_form(:full))
     |> assign(:operations?, false)
     |> assign(:include_flex, true)
     |> assign(:file_inventory, [])
     |> assign(:closure_count, 0)
     |> assign(:export_run, nil)
     |> assign(:export_notice, nil)
     |> assign(:export_defaults, nil)
     |> assign(:missing_summary, AsyncResult.loading())
     |> assign(:validation_run_id, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:recent_checks, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    ExportRuns.reconcile_expired(organization_id)
    ExportRuns.cleanup_expired(organization_id)

    organization = socket.assigns.current_organization
    export_type = resolve_export_type(params["type"], organization)

    {:noreply,
     socket
     |> assign(:operations?, ProductSurfaces.visible?(organization, :operations_export))
     |> assign(:export_type, export_type)
     |> assign(:export_form, export_form(export_type))
     |> assign(:export_notice, nil)
     |> assign(:include_flex, ExportDefaults.get(organization_id).include_flex)
     |> assign(:export_defaults, ExportDefaults.get(organization_id))
     |> refresh_export_run()
     |> refresh_file_inventory()
     |> assign_recent_checks()
     |> load_missing_summary()}
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      # Push event to JS hook to update localStorage
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      # Navigate to new version
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_export_type", %{"export" => %{"type" => type}}, socket) do
    # Whitelisted before it reaches the URL, so no arbitrary value or new atom
    # can travel through the query string; `handle_params/3` owns the refresh.
    if type in @export_type_params do
      {:noreply,
       push_patch(socket,
         to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/export?type=#{type}"
       )}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("run_validation", _params, socket),
    do: handle_run_validation(socket, "mobility_data")

  @impl Phoenix.LiveView
  def handle_event("run_flex_validation", _params, socket),
    do: handle_run_validation(socket, "mobility_data_flex")

  @impl Phoenix.LiveView
  def handle_event("reset_validation", _params, socket) do
    if socket.assigns.validation_run_id do
      Phoenix.PubSub.unsubscribe(
        GtfsPlanner.PubSub,
        Validations.topic(socket.assigns.validation_run_id)
      )
    end

    {:noreply,
     socket
     |> assign(:validation_run_id, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)}
  end

  @impl Phoenix.LiveView
  def handle_event("start_export", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    version = socket.assigns.current_gtfs_version
    socket = assign(socket, :export_notice, nil)

    with {:ok, run} <-
           ExportRuns.create_pending(
             organization_id,
             version.id,
             export_actor(socket),
             socket.assigns.export_type
           ),
         :ok <- subscribe_export_run(run),
         :ok <- ExportRunner.ensure_started(organization_id, run) do
      {:noreply, assign(socket, :export_run, run)}
    else
      {:error, :invalid_transition} ->
        {:noreply, refresh_export_run(socket)}

      {:error, :busy} ->
        {:noreply, export_busy(socket)}

      {:error, :artifact_storage_unavailable} ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> assign(
           :export_notice,
           "The export couldn’t start: this server can’t write export files. Ask an administrator to check the export storage location."
         )}

      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> assign(:export_notice, "The export couldn’t start. Try again.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_export", _params, socket) do
    socket = assign(socket, :export_notice, nil)

    with %{id: run_id} <- socket.assigns.export_run,
         {:ok, _run} <- ExportRuns.request_cancel(socket.assigns.current_organization.id, run_id) do
      {:noreply, refresh_export_run(socket)}
    else
      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> assign(
           :export_notice,
           "The export couldn’t be cancelled. Check the status below and try again."
         )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("retry_export", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    socket = assign(socket, :export_notice, nil)

    with %{id: run_id} <- socket.assigns.export_run,
         {:ok, run} <- ExportRuns.retry(organization_id, run_id),
         :ok <- subscribe_export_run(run),
         :ok <- ExportRunner.ensure_started(organization_id, run) do
      {:noreply, assign(socket, :export_run, run)}
    else
      {:error, :busy} ->
        {:noreply, export_busy(socket)}

      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> assign(:export_notice, "The export couldn’t be restarted. Try again.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:export_run_changed, _run_id}, socket) do
    {:noreply, refresh_export_run(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:validation_progress, progress}, socket) do
    {:noreply, assign(socket, :validation_progress, progress)}
  end

  # The run's row decides the outcome, so a message that was queued behind a
  # newer state, or a run that finished before this page subscribed, ends the
  # same way. A run the page no longer shows (reset, or a newer check) changes nothing.
  @impl Phoenix.LiveView
  def handle_info(
        {event, run_id},
        %{assigns: %{validation_run_id: run_id}} = socket
      )
      when event in [:validation_completed, :validation_failed] do
    {:noreply, apply_validation_outcome(socket, Validations.get_validation_run!(run_id))}
  end

  @impl Phoenix.LiveView
  def handle_info({event, _run_id}, socket)
      when event in [:validation_completed, :validation_failed] do
    {:noreply, socket}
  end

  defp apply_validation_outcome(socket, %{status: "completed"} = run) do
    socket
    |> assign_persisted_validation_result(run)
    |> assign(:validating, false)
    |> assign(:validation_progress, nil)
  end

  defp apply_validation_outcome(socket, %{status: "failed"}) do
    socket
    |> assign(:validation_error, :failed)
    |> assign(:validating, false)
    |> assign(:validation_progress, nil)
  end

  defp apply_validation_outcome(socket, _running_run), do: socket

  defp assign_persisted_validation_result(socket, run) do
    if run.organization_id != socket.assigns.current_organization.id do
      assign(socket, :validation_error, :other_organization)
    else
      socket
      |> assign(:validation_result, %{
        summary: %{
          errors: run.errors_count,
          warnings: run.warnings_count,
          infos: run.infos_count
        }
      })
      |> assign_recent_checks()
    end
  end

  @impl Phoenix.LiveView
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
      <:sub_header>
        <.gtfs_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:export} />
      </:sub_header>

      <div id="export-page" class="ds-page">
        <.header>
          Export feed
          <:subtitle>{lede(@current_gtfs_version, @operations?)}</:subtitle>
        </.header>

        <div
          id="export-download-container"
          class="mt-2 grid gap-6 lg:grid-cols-[minmax(0,1fr)_23rem] lg:items-start"
        >
          <div class="grid min-w-0 gap-6">
            <.result_section
              id="export-workspace"
              title="Create a feed file"
              lede={"Uses #{@current_gtfs_version.name} as it is now."}
            >
              <.type_options
                form={@export_form}
                export_type={@export_type}
                operations?={@operations?}
              />
              <.closures_omitted
                :if={@export_type == :pathways and @closure_count > 0}
                count={@closure_count}
              />
              <.operations_note :if={@export_type == :operations} file_inventory={@file_inventory} />
              <.contents
                export_type={@export_type}
                file_inventory={@file_inventory}
                missing_summary={@missing_summary}
                defaults={@export_defaults}
                version_id={@current_gtfs_version.id}
              />
              <.run_status
                run={@export_run}
                export_type={@export_type}
                version={@current_gtfs_version}
                notice={@export_notice}
                defaults={@export_defaults}
              />
            </.result_section>

            <.guide
              export_type={@export_type}
              version={@current_gtfs_version}
              organization={@current_organization}
            />
          </div>

          <div class="grid min-w-0 gap-6">
            <.check_panel
              validating?={@validating}
              progress={@validation_progress}
              result={@validation_result}
              error={@validation_error}
              validation_run_id={@validation_run_id}
              version={@current_gtfs_version}
              include_flex={@include_flex}
            />
            <.recent_checks :if={@recent_checks != []} checks={@recent_checks} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp lede(version, operations?) do
    "Create a file of #{version.name} for trip planners such as Google Maps and Transit app" <>
      if(operations?, do: ", or for your CAD/AVL vendor.", else: ".")
  end

  # The title a check carries in Recent checks: a plain name for the kind of check.
  defp check_title(%{run_type: "mobility_data"}, _station_names_by_run_id), do: "Feed check"

  defp check_title(%{run_type: "mobility_data_flex"}, _station_names_by_run_id),
    do: "Flex file check"

  defp check_title(%{run_type: "pathways_tests"}, _station_names_by_run_id),
    do: "Pathways test"

  defp check_title(%{run_type: "station_reachability", id: run_id}, station_names_by_run_id) do
    case Map.get(station_names_by_run_id, run_id) do
      station_name when is_binary(station_name) and station_name != "" ->
        "Station reachability · #{station_name}"

      _other ->
        "Station reachability"
    end
  end

  defp check_title(%{run_type: type}, _station_names_by_run_id), do: type

  defp recent_validation_display_counts(%{run_type: "pathways_tests", result_json: result_json})
       when is_map(result_json) do
    summary = Map.get(result_json, "summary", %{})

    %{
      errors: Map.get(summary, "scoring_failure", 0),
      warnings: Map.get(summary, "query_failure", 0),
      infos: Map.get(summary, "passed", 0)
    }
  end

  defp recent_validation_display_counts(run) do
    %{
      errors: run.errors_count,
      warnings: run.warnings_count,
      infos: run.infos_count
    }
  end

  defp build_recent_validation_station_names_map(runs, organization_id, gtfs_version_id) do
    runs
    |> Enum.reduce(%{}, fn run, station_names_by_run_id ->
      case station_reachability_station_stop_id(run) do
        nil ->
          station_names_by_run_id

        station_stop_id ->
          case station_name_for_stop_id(organization_id, gtfs_version_id, station_stop_id) do
            nil -> station_names_by_run_id
            station_name -> Map.put(station_names_by_run_id, run.id, station_name)
          end
      end
    end)
  end

  defp station_reachability_station_stop_id(%{
         run_type: "station_reachability",
         result_json: result_json
       })
       when is_map(result_json) do
    metadata = payload_value(result_json, :metadata)

    payload_value(metadata, :station_stop_id) || payload_value(result_json, :station_stop_id)
  end

  defp station_reachability_station_stop_id(_run), do: nil

  defp station_name_for_stop_id(organization_id, gtfs_version_id, station_stop_id)
       when is_binary(station_stop_id) do
    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, station_stop_id) do
      %{stop_name: stop_name, stop_id: stop_id} ->
        if is_binary(stop_name) and stop_name != "", do: stop_name, else: stop_id

      _other ->
        nil
    end
  end

  defp station_name_for_stop_id(_organization_id, _gtfs_version_id, _station_stop_id), do: nil

  defp validation_run_results_path(gtfs_version_id, run) do
    case station_reachability_station_stop_id(run) do
      station_stop_id when is_binary(station_stop_id) and station_stop_id != "" ->
        ~p"/gtfs/#{gtfs_version_id}/station-reachability/#{run.id}?stop_id=#{station_stop_id}"

      _other ->
        if run.run_type == "station_reachability" do
          ~p"/gtfs/#{gtfs_version_id}/station-reachability/#{run.id}"
        else
          ~p"/gtfs/#{gtfs_version_id}/validation/#{run.id}"
        end
    end
  end

  defp assign_recent_checks(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    runs = Validations.list_recent_validation_runs(organization_id, gtfs_version_id, 5)

    station_names =
      build_recent_validation_station_names_map(runs, organization_id, gtfs_version_id)

    assign(
      socket,
      :recent_checks,
      Enum.map(runs, fn run ->
        counts = recent_validation_display_counts(run)

        %{
          id: run.id,
          title: check_title(run, station_names),
          started_at: run.started_at,
          path: validation_run_results_path(gtfs_version_id, run),
          kind: if(run.run_type == "pathways_tests", do: :pathways_test, else: :severity),
          errors: counts.errors,
          warnings: counts.warnings,
          infos: counts.infos
        }
      end)
    )
  end

  defp payload_value(nil, _key), do: nil

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  defp run_mobility_data_validation(socket, organization_id, gtfs_version_id, run_type) do
    case Validations.start_mobility_data_run(
           organization_id,
           gtfs_version_id,
           run_type,
           export_actor(socket)
         ) do
      {:ok, run} ->
        # Subscribe, then read the row: a run that finished before the
        # subscription has no message coming.
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(run.id))

        {:noreply,
         socket
         |> assign(:validation_run_id, run.id)
         |> assign(:validating, true)
         |> assign(:validation_progress, %{phase: :starting, percent: 0})
         |> assign(:validation_result, nil)
         |> assign(:validation_error, nil)
         |> apply_validation_outcome(Validations.get_validation_run!(run.id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, @validation_busy_message)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, @validation_permission_message)}

      {:error, _reason} ->
        {:noreply, assign(socket, :validation_error, :not_started)}
    end
  end

  defp handle_run_validation(socket, run_type) do
    if socket.assigns.validating do
      {:noreply, put_flash(socket, :error, "A check is already running.")}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      run_mobility_data_validation(socket, organization_id, gtfs_version_id, run_type)
    end
  end

  defp export_form(export_type),
    do: to_form(%{"type" => Atom.to_string(export_type)}, as: :export)

  defp export_type_from_param("pathways"), do: :pathways
  defp export_type_from_param("operations"), do: :operations
  defp export_type_from_param(_type), do: :full

  # ProductSurfaces alone decides visibility (INV-1): a Pathways organization
  # never selects the operations export, so its query param falls back to full.
  defp resolve_export_type(type_param, organization) do
    case export_type_from_param(type_param) do
      :operations ->
        if ProductSurfaces.visible?(organization, :operations_export),
          do: :operations,
          else: :full

      export_type ->
        export_type
    end
  end

  defp export_actor(socket) do
    %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
  end

  defp refresh_file_inventory(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    export_type = socket.assigns.export_type
    # The operations export packages the full GTFS file set; its TODS additions
    # come from the organization, not from the version.
    base_type = if export_type == :operations, do: :full, else: export_type

    file_inventory =
      organization_id
      |> Gtfs.get_file_inventory(version_id, base_type)
      |> Kernel.++(tods_inventory(organization_id, export_type))
      |> Enum.sort_by(fn {filename, _count} -> filename end)

    # The omission notice reads the published closure count through the same
    # scope the Evolutions surface uses; the route only mounts a published
    # version, so it matches the rows the full inventory reports.
    socket
    |> assign(:file_inventory, file_inventory)
    |> assign(:closure_count, Gtfs.count_closures(organization_id, version_id))
  end

  defp tods_inventory(organization_id, :operations),
    do: Operations.tods_file_inventory(organization_id)

  defp tods_inventory(_organization_id, _export_type), do: []

  # The runner supervisor is full. The run that never started is already closed,
  # so the page goes back to the export it was showing and says why.
  defp export_busy(socket) do
    socket
    |> refresh_export_run()
    |> assign(:export_notice, @export_busy_message)
  end

  defp refresh_export_run(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    export_run =
      ExportRuns.latest_for_version(organization_id, version_id, socket.assigns.export_type)

    if export_run, do: subscribe_export_run(export_run)
    assign(socket, :export_run, export_run)
  end

  defp subscribe_export_run(run),
    do: Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ExportRuns.topic(run))

  # The version's missing-times count loads apart from the file list, so a
  # large version never blocks the page; the pre-run line reads it when ready.
  defp load_missing_summary(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :missing_summary, fn ->
      {:ok, %{missing_summary: MissingTimes.summary(organization_id, version_id)}}
    end)
  end
end
