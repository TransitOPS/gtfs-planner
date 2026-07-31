defmodule GtfsPlannerWeb.Gtfs.ExportLive do
  @moduledoc """
  LiveView for exporting GTFS data.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export.Runner, as: ExportRunner
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  require Logger
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Export GTFS")
     |> assign(:user_roles, user_roles)
     |> assign(:export_type, :full)
     |> assign(:export_form, export_form(:full))
     |> assign(:file_inventory, [])
     |> assign(:export_run, nil)
     |> assign(:validation_run_id, nil)
     |> assign(:validation_task, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:recent_validation_display_counts_by_run_id, %{})
     |> assign(:recent_validation_station_names_by_run_id, %{})
     |> assign(:recent_validation_runs, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    ExportRuns.reconcile_expired(organization_id)
    ExportRuns.cleanup_expired(organization_id)

    {:noreply,
     socket
     |> refresh_export_run()
     |> refresh_file_inventory()
     |> assign_recent_validation_data()}
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
    # Use whitelist mapping to prevent atom exhaustion from user input
    export_type =
      case type do
        "full" -> :full
        "pathways" -> :pathways
        _ -> :full
      end

    {:noreply,
     socket
     |> assign(:export_type, export_type)
     |> assign(:export_form, export_form(export_type))
     |> refresh_file_inventory()
     |> refresh_export_run()}
  end

  @impl Phoenix.LiveView
  def handle_event("run_validation", _params, socket) do
    if socket.assigns.validating do
      {:noreply, put_flash(socket, :error, "Validation already in progress")}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      run_mobility_data_validation(socket, organization_id, gtfs_version_id)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("reset_validation", _params, socket) do
    if socket.assigns.validation_run_id do
      Phoenix.PubSub.unsubscribe(
        GtfsPlanner.PubSub,
        "validation:#{socket.assigns.validation_run_id}"
      )
    end

    {:noreply,
     socket
     |> assign(:validation_run_id, nil)
     |> assign(:validation_task, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)}
  end

  @impl Phoenix.LiveView
  def handle_event("start_export", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    version = socket.assigns.current_gtfs_version

    with {:ok, run} <-
           ExportRuns.create_pending(
             organization_id,
             version.id,
             export_actor(socket),
             socket.assigns.export_type
           ),
         :ok <- subscribe_export_run(run),
         :ok <- maybe_start_export_run(organization_id, run) do
      {:noreply, assign(socket, :export_run, run)}
    else
      {:error, :invalid_transition} ->
        {:noreply, refresh_export_run(socket)}

      {:error, :artifact_storage_unavailable} ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> put_flash(
           :error,
           "The export could not start: this server cannot write export files. Ask an administrator to check the export storage location."
         )}

      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> put_flash(:error, "Could not start the export. Try again.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_export", _params, socket) do
    with %{id: run_id} <- socket.assigns.export_run,
         {:ok, _run} <- ExportRuns.request_cancel(socket.assigns.current_organization.id, run_id) do
      {:noreply, refresh_export_run(socket)}
    else
      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> put_flash(:error, "The export could not be cancelled.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("retry_export", _params, socket) do
    organization_id = socket.assigns.current_organization.id

    with %{id: run_id} <- socket.assigns.export_run,
         {:ok, run} <- ExportRuns.retry(organization_id, run_id),
         :ok <- subscribe_export_run(run),
         {:ok, _pid} <- ExportRunner.start_build(organization_id, run.id) do
      {:noreply, assign(socket, :export_run, run)}
    else
      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> put_flash(:error, "The export could not be restarted.")}
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

  @impl Phoenix.LiveView
  def handle_info({ref, result}, socket) do
    if socket.assigns.validation_task && socket.assigns.validation_task.ref == ref do
      handle_validation_result(ref, result, socket)
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns.validation_task && socket.assigns.validation_task.ref == ref do
      Logger.error("Validation task crashed: #{inspect(reason)}")

      {:noreply,
       socket
       |> assign(:validation_error, "Validation failed unexpectedly")
       |> assign(:validating, false)
       |> assign(:validation_task, nil)
       |> assign(:validation_progress, nil)}
    else
      {:noreply, socket}
    end
  end

  defp handle_validation_result(ref, result, socket) do
    Process.demonitor(ref, [:flush])
    socket = apply_validation_result(socket, result)

    {:noreply,
     socket
     |> assign(:validating, false)
     |> assign(:validation_task, nil)}
  end

  defp apply_validation_result(socket, {:ok, %Validator.Result{}}) do
    run = Validations.get_validation_run!(socket.assigns.validation_run_id)
    assign_persisted_validation_result(socket, run)
  end

  defp apply_validation_result(socket, {:error, reason}) do
    assign(socket, :validation_error, "Validation failed: #{inspect(reason)}")
  end

  defp assign_persisted_validation_result(socket, run) do
    if run.organization_id != socket.assigns.current_organization.id do
      assign(socket, :validation_error, "Unauthorized access to validation run")
    else
      socket
      |> assign(:validation_result, %{
        summary: %{
          errors: run.errors_count,
          warnings: run.warnings_count,
          infos: run.infos_count
        }
      })
      |> assign_recent_validation_data()
    end
  end

  attr :export_warnings, :list, required: true

  defp export_warning_panel(assigns) do
    ~H"""
    <div id="export-warning-panel" role="alert" class="alert alert-warning mt-6">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="stroke-current shrink-0 h-6 w-6"
        fill="none"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
        />
      </svg>
      <div>
        <h3 class="font-bold">
          {length(@export_warnings)} data quality warning{if length(@export_warnings) == 1,
            do: "",
            else: "s"}
        </h3>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={issue <- @export_warnings} class="border-l-2 border-warning/60 pl-3">
            <p>{Map.get(issue, :detail, Map.get(issue, "detail", "Preflight reported an issue"))}</p>
            <% details_line = format_export_warning_details(issue) %>
            <p
              :if={details_line}
              class="mt-0.5 font-mono text-xs opacity-80"
            >
              {details_line}
            </p>
          </li>
        </ul>
      </div>
    </div>
    """
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
      <.header>
        Export & Validate
        <:subtitle>
          Generate GTFS exports and run validation checks to ensure data quality before publishing.
        </:subtitle>
      </.header>

      <%!-- Version Info Card --%>
      <div class="mt-6 bg-base-100 rounded-lg p-6 border border-base-300">
        <div class="flex items-center gap-3">
          <div class="flex-1">
            <h2 class="text-xl font-semibold text-base-content">
              {@current_gtfs_version.name}
            </h2>
            <p class="text-sm text-base-content/60 mt-1">
              GTFS Version for {@current_organization.name}
            </p>
          </div>
        </div>
      </div>

      <div id="export-download-container" class="grid grid-cols-1 lg:grid-cols-2 gap-8 mt-8">
        <%!-- Export Column --%>
        <section id="export-workspace" class="bg-base-100 rounded-lg p-6 border border-base-300">
          <h2 class="text-lg font-semibold mb-2">Export</h2>
          <p class="text-sm text-base-content/70 mb-4">
            Generate a GTFS zip file containing all data from this version. The export includes all required and optional GTFS files with current record counts.
          </p>

          <.form
            for={@export_form}
            id="gtfs-export-form"
            phx-change="select_export_type"
            class="mt-5 max-w-xl"
          >
            <fieldset>
              <legend class="text-sm font-medium">Export type</legend>
              <div class="mt-2 grid gap-2 sm:grid-cols-2">
                <label class="flex min-h-11 items-center gap-2 border border-base-300 px-3 py-2 cursor-pointer has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                  <input
                    type="radio"
                    id="export-type-full"
                    name={@export_form[:type].name}
                    value="full"
                    checked={@export_type == :full}
                    class="radio radio-sm"
                  />
                  <span class="text-sm font-medium">Full export</span>
                </label>
                <label class="flex min-h-11 items-center gap-2 border border-base-300 px-3 py-2 cursor-pointer has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                  <input
                    type="radio"
                    id="export-type-pathways"
                    name={@export_form[:type].name}
                    value="pathways"
                    checked={@export_type == :pathways}
                    class="radio radio-sm"
                  />
                  <span class="text-sm font-medium">Pathways export</span>
                </label>
              </div>
            </fieldset>
          </.form>

          <div id="export-inventory" class="mt-6 overflow-x-auto border-y border-base-300">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b border-base-300 text-left text-xs font-medium text-base-content/70">
                  <th class="py-2">File</th>
                  <th class="py-2 text-right">Records</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{filename, count} <- @file_inventory}
                  class="border-b border-base-200 last:border-0 hover:bg-base-200/60"
                >
                  <td class="py-2 font-mono text-xs">{filename}</td>
                  <td class="py-2 text-right tabular-nums">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <.empty_state
            :if={@file_inventory == []}
            id="export-empty-inventory"
            title="No files in this export"
          >
            This export type has no GTFS tables to package yet.
          </.empty_state>

          <div id="export-run-status" class="mt-6">
            <%= if @export_run do %>
              <.status_badge
                status={export_badge_status(@export_run)}
                label={export_state_label(@export_run)}
              />
              <p class="mt-2 text-sm text-base-content/70">{export_state_detail(@export_run)}</p>
              <.export_warning_panel
                :if={@export_run.warnings != []}
                export_warnings={@export_run.warnings}
              />
              <.link
                :if={@export_run.state == :ready}
                id="export-download-link"
                href={~p"/gtfs/#{@current_gtfs_version.id}/export-runs/#{@export_run.id}/download"}
                class="btn btn-primary mt-4 min-h-11"
              >
                Download ZIP
              </.link>
              <.button
                :if={
                  @export_run.state in [:pending, :building] and
                    is_nil(@export_run.cancel_requested_at)
                }
                id="cancel-export"
                phx-click="cancel_export"
                variant="secondary"
                class="mt-4"
              >
                Cancel export
              </.button>
              <.button
                :if={@export_run.state in [:failed, :interrupted, :cancelled, :expired]}
                id="retry-export"
                phx-click="retry_export"
                class="mt-4"
              >
                Retry export
              </.button>
            <% else %>
              <.empty_state id="export-empty-history" title="No export yet">
                Start an export to create a downloadable, time-limited artifact.
              </.empty_state>
            <% end %>
          </div>

          <.button
            id="start-export"
            phx-click="start_export"
            disabled={export_start_disabled?(@export_run)}
            class="mt-6 w-full"
          >
            {export_start_label(@export_run)}
          </.button>
        </section>

        <%!-- Validate Column --%>
        <div class="bg-base-100 rounded-lg p-6 border border-base-300">
          <h2 class="text-lg font-semibold mb-2">Validate</h2>
          <p class="text-sm text-base-content/70 mb-6">
            Run the MobilityData GTFS Validator against this version to find spec violations before publishing.
          </p>

          <%= if @validation_error do %>
            <section
              id="validation-error-panel"
              role="alert"
              class="mb-6 rounded-xl border border-error/40 bg-base-100 px-4 py-3"
            >
              <div class="flex items-start gap-3">
                <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 shrink-0 text-error" />
                <p id="validation-error-content" class="text-sm leading-5 text-base-content">
                  {@validation_error}
                </p>
              </div>
            </section>
          <% end %>

          <%= cond do %>
            <% @validating -> %>
              <div class="space-y-4">
                <progress
                  class="progress progress-primary w-full"
                  value={@validation_progress.percent}
                  max="100"
                />
                <div class="flex items-center gap-2">
                  <span class="loading loading-spinner loading-sm"></span>
                  <span class="text-sm">{phase_label(@validation_progress.phase)}</span>
                </div>
              </div>
            <% @validation_result -> %>
              <div class="space-y-6">
                <.count_strip
                  id="mobility-summary-metrics"
                  items={mobility_result_count_items(@validation_result.summary)}
                />

                <div class="flex flex-col gap-2">
                  <.link
                    navigate={~p"/gtfs/#{@current_gtfs_version.id}/validation/#{@validation_run_id}"}
                    class="btn btn-primary btn-sm w-full"
                  >
                    View full results
                  </.link>
                  <button class="btn btn-outline btn-sm w-full" phx-click="reset_validation">
                    Run validation again
                  </button>
                </div>
              </div>
            <% true -> %>
              <.button
                id="run-validation"
                phx-click="run_validation"
                variant="secondary"
                class="w-full"
              >
                Run validation
              </.button>
          <% end %>

          <%!-- Recent Validations --%>
          <%= if @recent_validation_runs != [] do %>
            <div class="mt-8 pt-8 border-t border-base-300">
              <h3 class="text-sm font-semibold mb-4">Recent Validations</h3>
              <.count_strip
                id="validation-history-counts"
                items={validation_history_count_items(@recent_validation_runs)}
                class="mb-4"
              />
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Type</th>
                      <th>Date</th>
                      <th class="text-right">Errors</th>
                      <th class="text-right">Warnings</th>
                      <th class="text-right">Infos</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={run <- @recent_validation_runs}>
                      <% display_counts =
                        Map.get(
                          @recent_validation_display_counts_by_run_id,
                          run.id,
                          recent_validation_display_counts(run)
                        ) %>
                      <td>
                        <.link
                          navigate={validation_run_results_path(@current_gtfs_version.id, run)}
                          class="link link-primary"
                        >
                          {format_run_type(run, @recent_validation_station_names_by_run_id)}
                        </.link>
                      </td>
                      <td class="text-sm text-base-content/70">
                        {format_date(run.started_at)}
                      </td>
                      <td colspan="3" class="text-right">
                        <.count_strip
                          id={"recent-validation-counts-#{run.id}"}
                          items={recent_validation_count_items(display_counts)}
                          class="justify-end"
                        />
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp phase_label(:exporting), do: "Exporting GTFS data..."
  defp phase_label(:validating), do: "Running validator..."
  defp phase_label(:processing), do: "Processing results..."
  defp phase_label(_), do: "Preparing..."

  defp format_run_type(%{run_type: "mobility_data"}, _station_names_by_run_id),
    do: "MobilityData"

  defp format_run_type(%{run_type: "pathways_tests"}, _station_names_by_run_id),
    do: "Pathways Tests"

  defp format_run_type(
         %{run_type: "station_reachability", id: run_id},
         station_names_by_run_id
       )
       when is_map(station_names_by_run_id) do
    case Map.get(station_names_by_run_id, run_id) do
      station_name when is_binary(station_name) and station_name != "" ->
        "Station Reachability - #{station_name}"

      _other ->
        "Station Reachability"
    end
  end

  defp format_run_type(%{run_type: type}, _station_names_by_run_id), do: type

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

  defp build_recent_validation_display_counts_map(runs) do
    runs
    |> Enum.map(fn run ->
      {run.id, recent_validation_display_counts(run)}
    end)
    |> Map.new()
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

  defp assign_recent_validation_data(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    recent_validation_runs =
      Validations.list_recent_validation_runs(organization_id, gtfs_version_id, 5)

    recent_validation_display_counts_by_run_id =
      build_recent_validation_display_counts_map(recent_validation_runs)

    recent_validation_station_names_by_run_id =
      build_recent_validation_station_names_map(
        recent_validation_runs,
        organization_id,
        gtfs_version_id
      )

    socket
    |> assign(
      :recent_validation_display_counts_by_run_id,
      recent_validation_display_counts_by_run_id
    )
    |> assign(
      :recent_validation_station_names_by_run_id,
      recent_validation_station_names_by_run_id
    )
    |> assign(:recent_validation_runs, recent_validation_runs)
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  defp payload_value(nil, _key), do: nil

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  defp run_mobility_data_validation(socket, organization_id, gtfs_version_id) do
    case Validations.create_validation_run(organization_id, gtfs_version_id, "mobility_data") do
      {:ok, run} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "validation:#{run.id}")
        end

        validator_module = Application.fetch_env!(:gtfs_planner, :validator_module)

        task =
          Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
            validator_module.validate(organization_id, gtfs_version_id, validation_run_id: run.id)
          end)

        {:noreply,
         socket
         |> assign(:validation_run_id, run.id)
         |> assign(:validation_task, task)
         |> assign(:validating, true)
         |> assign(:validation_progress, %{phase: :starting, percent: 0})
         |> assign(:validation_result, nil)
         |> assign(:validation_error, nil)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create validation run")}
    end
  end

  defp export_form(export_type),
    do: to_form(%{"type" => Atom.to_string(export_type)}, as: :export)

  defp mobility_result_count_items(summary) do
    [
      %{key: "errors", label: "Errors", count: summary.errors, tone: :error},
      %{key: "warnings", label: "Warnings", count: summary.warnings, tone: :warning},
      %{key: "infos", label: "Information", count: summary.infos, tone: :info}
    ]
  end

  defp recent_validation_count_items(counts) do
    [
      %{key: "errors", label: "Errors", count: counts.errors, tone: :error},
      %{key: "warnings", label: "Warnings", count: counts.warnings, tone: :warning},
      %{key: "infos", label: "Information", count: counts.infos, tone: :info}
    ]
  end

  defp validation_history_count_items(runs) do
    Enum.reduce(runs, %{errors: 0, warnings: 0, infos: 0}, fn run, totals ->
      counts = recent_validation_display_counts(run)

      %{
        errors: totals.errors + positive_count(counts.errors),
        warnings: totals.warnings + positive_count(counts.warnings),
        infos: totals.infos + positive_count(counts.infos)
      }
    end)
    |> recent_validation_count_items()
  end

  defp positive_count(count) when count > 0, do: 1
  defp positive_count(_count), do: 0

  defp export_actor(socket) do
    %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
  end

  defp maybe_start_export_run(organization_id, %{state: :pending, id: run_id}) do
    case ExportRunner.start_build(organization_id, run_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :claim_failed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_export_run(_organization_id, _active_run), do: :ok

  defp refresh_file_inventory(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    file_inventory =
      organization_id
      |> Gtfs.get_file_inventory(version_id, socket.assigns.export_type)
      |> Enum.sort_by(fn {filename, _count} -> filename end)

    assign(socket, :file_inventory, file_inventory)
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

  defp export_start_disabled?(%{state: state}) when state in [:pending, :building], do: true
  defp export_start_disabled?(_run), do: false

  defp export_start_label(%{state: state}) when state in [:pending, :building],
    do: "Export in progress"

  defp export_start_label(_run), do: "Export GTFS"

  defp export_badge_status(%{state: :ready}), do: :completed
  defp export_badge_status(%{state: state}) when state in [:pending, :building], do: :running
  defp export_badge_status(%{state: :cancelled}), do: :warning
  defp export_badge_status(%{state: :expired}), do: :warning
  defp export_badge_status(%{state: _state}), do: :failed

  defp export_state_label(%{state: :pending}), do: "Queued"
  defp export_state_label(%{state: :building, cancel_requested_at: nil}), do: "Building"
  defp export_state_label(%{state: :building}), do: "Cancellation requested"
  defp export_state_label(%{state: :ready}), do: "Ready to download"
  defp export_state_label(%{state: :failed}), do: "Export failed"
  defp export_state_label(%{state: :interrupted}), do: "Export interrupted"
  defp export_state_label(%{state: :cancelled}), do: "Export cancelled"
  defp export_state_label(%{state: :expired}), do: "Download expired"

  defp export_state_detail(%{state: :ready}),
    do: "The artifact is ready. Download links expire after the retention period."

  defp export_state_detail(%{state: :building, cancel_requested_at: nil}),
    do: "Packaging your GTFS data. You can leave this page and return later."

  defp export_state_detail(%{state: :building}),
    do: "Cancellation will take effect at the next safe build boundary."

  defp export_state_detail(%{state: :failed, failure_code: "artifact_storage_unavailable"}),
    do:
      "The build finished but could not be saved: this server cannot write export files. Ask an administrator to check the export storage location."

  defp export_state_detail(%{state: :expired}),
    do: "The download artifact has expired. Create a new export to download it."

  defp export_state_detail(%{state: :cancelled}),
    do: "This export was cancelled before an artifact was published."

  defp export_state_detail(%{state: :interrupted}),
    do: "The build stopped before publishing an artifact. Retry to create a new one."

  defp export_state_detail(%{state: :failed}),
    do: "The build did not publish an artifact. Retry to create a new one."

  defp export_state_detail(%{state: :pending}),
    do: "Your export is queued and will begin shortly."

  defp format_export_warning_details(issue) do
    issue
    |> Map.get(:code, Map.get(issue, "code"))
    |> case do
      nil -> nil
      code -> "Code: #{code}"
    end
  end
end
