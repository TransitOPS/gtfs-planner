defmodule GtfsPlannerWeb.Gtfs.ExportLive do
  @moduledoc """
  LiveView for exporting GTFS data.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Otp.Runtime
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
     |> assign(:selected_validations, [])
     |> assign(:file_inventory, [])
     |> assign(:exporting, false)
     |> assign(:export_task, nil)
     |> assign(:export_error, nil)
     |> assign(:validation_run_id, nil)
     |> assign(:validation_task, nil)
     |> assign(:pathways_prep_task, nil)
     |> assign(:pending_mobility_validation, false)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:pathways_prep_error, nil)
     |> assign(:recent_validation_runs, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    export_type = socket.assigns.export_type

    file_inventory =
      organization_id
      |> Gtfs.get_file_inventory(gtfs_version_id, export_type)
      |> Enum.sort_by(fn {filename, _count} -> filename end)

    recent_validation_runs =
      Validations.list_recent_validation_runs(organization_id, gtfs_version_id, 5)

    {:noreply,
     socket
     |> assign(:file_inventory, file_inventory)
     |> assign(:recent_validation_runs, recent_validation_runs)}
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         valid_version_for_org?(version_id, current_organization.id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    # Push event to JS hook to update localStorage
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    # Navigate to new version
    {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
  end

  @impl Phoenix.LiveView
  def handle_event("select_export_type", %{"type" => type}, socket) do
    # Use whitelist mapping to prevent atom exhaustion from user input
    export_type =
      case type do
        "full" -> :full
        "pathways" -> :pathways
        _ -> :full
      end

    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    file_inventory =
      organization_id
      |> Gtfs.get_file_inventory(gtfs_version_id, export_type)
      |> Enum.sort_by(fn {filename, _count} -> filename end)

    {:noreply,
     socket
     |> assign(:export_type, export_type)
     |> assign(:file_inventory, file_inventory)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_validation", %{"validation" => validation}, socket) do
    # Whitelist allowed validation types to prevent unbounded atom creation
    validation_atom =
      case validation do
        "mobility_data" -> :mobility_data
        "pathways_tests" -> :pathways_tests
        # ignore unknown validation types
        _ -> nil
      end

    current_validations = socket.assigns.selected_validations

    updated_validations =
      if validation_atom do
        if validation_atom in current_validations do
          List.delete(current_validations, validation_atom)
        else
          [validation_atom | current_validations]
        end
      else
        # If validation_atom is nil (unknown type), don't modify the list
        current_validations
      end

    {:noreply, assign(socket, :selected_validations, updated_validations)}
  end

  @impl Phoenix.LiveView
  def handle_event("run_validation", _params, socket) do
    selected_validations = socket.assigns.selected_validations

    cond do
      socket.assigns.validating ->
        {:noreply, put_flash(socket, :error, "Validation already in progress")}

      selected_validations == [] ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Select at least one validation check before running validation"
         )}

      true ->
        organization_id = socket.assigns.current_organization.id
        gtfs_version_id = socket.assigns.current_gtfs_version.id
        has_pathways_tests = Enum.member?(selected_validations, :pathways_tests)

        if has_pathways_tests do
          start_pathways_prep(socket, selected_validations, organization_id, gtfs_version_id)
        else
          run_mobility_data_validation(socket, organization_id, gtfs_version_id)
        end
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
     |> assign(:pathways_prep_task, nil)
     |> assign(:pending_mobility_validation, false)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)}
  end

  @impl Phoenix.LiveView
  def handle_event("download_export", _params, socket) do
    if socket.assigns.exporting do
      {:noreply, put_flash(socket, :error, "Export already in progress")}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      export_type = socket.assigns.export_type

      task =
        Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
          GtfsPlanner.Gtfs.Export.export_to_zip(organization_id, gtfs_version_id, export_type)
        end)

      {:noreply,
       socket
       |> assign(:export_task, task)
       |> assign(:exporting, true)
       |> assign(:export_error, nil)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:validation_progress, progress}, socket) do
    {:noreply, assign(socket, :validation_progress, progress)}
  end

  @impl Phoenix.LiveView
  def handle_info({:pathways_prep_progress, payload}, socket) do
    phase = pathways_prep_phase(payload)

    {:noreply,
     assign(socket, :validation_progress, %{
       phase: {:pathways_prep, phase},
       percent: phase_percent(phase)
     })}
  end

  @impl Phoenix.LiveView
  def handle_info({ref, result}, socket) do
    cond do
      socket.assigns.pathways_prep_task && socket.assigns.pathways_prep_task.ref == ref ->
        Process.demonitor(ref, [:flush])

        socket = assign(socket, :pathways_prep_task, nil)

        case result do
          :ok ->
            if socket.assigns.pending_mobility_validation do
              run_mobility_data_validation(
                socket |> assign(:pending_mobility_validation, false),
                socket.assigns.current_organization.id,
                socket.assigns.current_gtfs_version.id
              )
            else
              {:noreply,
               socket
               |> assign(:pending_mobility_validation, false)
               |> assign(:validating, false)
               |> assign(:validation_progress, nil)
               |> put_flash(
                 :info,
                 "Pathways trip test run started. Export preparation complete."
               )}
            end

          {:error, {:pathways_export_prep_failed, issues}} ->
            Logger.error("Pathways export preparation failed",
              event: "pathways_prep_failed",
              organization_id: socket.assigns.current_organization.id,
              gtfs_version_id: socket.assigns.current_gtfs_version.id,
              phase: :pathways_prep,
              issue_codes: Enum.map(issues, & &1.code),
              details: issues
            )

            {:noreply,
             socket
             |> assign(:pending_mobility_validation, false)
             |> assign(:validating, false)
             |> assign(:validation_progress, nil)
             |> assign(:pathways_prep_error, build_pathways_prep_error(issues))}
        end

      socket.assigns.export_task && socket.assigns.export_task.ref == ref ->
        Process.demonitor(ref, [:flush])

        socket =
          case result do
            {:ok, zip_binary} ->
              version_name = socket.assigns.current_gtfs_version.name
              filename = "gtfs_#{version_name}_#{Date.utc_today()}.zip"

              socket
              |> push_event("download-file", %{
                data: Base.encode64(zip_binary),
                filename: filename
              })
              |> put_flash(:info, "Export completed successfully")

            {:error, reason} ->
              error_message =
                case reason do
                  :no_data -> "No data available to export"
                  _ -> "Export failed: #{inspect(reason)}"
                end

              socket
              |> put_flash(:error, error_message)
              |> assign(:export_error, error_message)
          end

        {:noreply,
         socket
         |> assign(:exporting, false)
         |> assign(:export_task, nil)}

      socket.assigns.validation_task && socket.assigns.validation_task.ref == ref ->
        Process.demonitor(ref, [:flush])

        socket =
          case result do
            {:ok, %Validator.Result{} = _validation_result} ->
              case Runtime.cleanup_on_success(
                     socket.assigns.current_organization.id,
                     socket.assigns.current_gtfs_version.id
                   ) do
                :ok ->
                  :ok

                {:error, reason} ->
                  require Logger
                  Logger.error("Runtime.cleanup_on_success failed: #{inspect(reason)}")

                other ->
                  require Logger

                  Logger.error(
                    "Runtime.cleanup_on_success returned unexpected result: #{inspect(other)}"
                  )
              end

              # Result is now persisted in DB, just show success and keep validation_result for display
              run = Validations.get_validation_run!(socket.assigns.validation_run_id)

              # Verify authorization: ensure the run belongs to the current organization
              if run.organization_id != socket.assigns.current_organization.id do
                socket
                |> assign(:validation_error, "Unauthorized access to validation run")
              else
                # Refresh recent validation runs list
                recent_validation_runs =
                  Validations.list_recent_validation_runs(
                    socket.assigns.current_organization.id,
                    socket.assigns.current_gtfs_version.id,
                    5
                  )

                socket
                |> assign(:validation_result, %{
                  summary: %{
                    errors: run.errors_count,
                    warnings: run.warnings_count,
                    infos: run.infos_count
                  }
                })
                |> assign(:recent_validation_runs, recent_validation_runs)
              end

            {:error, reason} ->
              error_message = "Validation failed: #{inspect(reason)}"

              socket
              |> assign(:validation_error, error_message)
          end

        {:noreply,
         socket
         |> assign(:validating, false)
         |> assign(:validation_task, nil)}

      true ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    cond do
      socket.assigns.pathways_prep_task && socket.assigns.pathways_prep_task.ref == ref ->
        Logger.error("Pathways prep task crashed",
          event: "pathways_prep_failed",
          organization_id: socket.assigns.current_organization.id,
          gtfs_version_id: socket.assigns.current_gtfs_version.id,
          phase: :pathways_prep,
          reason: inspect(reason)
        )

        {:noreply,
         socket
         |> assign(:pathways_prep_error, %{
           summary: "Pathways export preparation crashed unexpectedly.",
           issues: [
             %{
               code: :task_crashed,
               message: inspect(reason),
               details: %{}
             }
           ],
           phase: :pathways_prep,
           log_ref: nil
         })
         |> assign(:validating, false)
         |> assign(:pathways_prep_task, nil)
         |> assign(:pending_mobility_validation, false)
         |> assign(:validation_progress, nil)}

      socket.assigns.export_task && socket.assigns.export_task.ref == ref ->
        require Logger
        Logger.error("Export task crashed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Export failed unexpectedly")
         |> assign(:export_error, "Export failed unexpectedly")
         |> assign(:exporting, false)
         |> assign(:export_task, nil)}

      socket.assigns.validation_task && socket.assigns.validation_task.ref == ref ->
        require Logger
        Logger.error("Validation task crashed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:validation_error, "Validation failed unexpectedly")
         |> assign(:validating, false)
         |> assign(:validation_task, nil)
         |> assign(:validation_progress, nil)}

      true ->
        {:noreply, socket}
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

      <div
        id="export-download-container"
        phx-hook=".DownloadHook"
        class="grid grid-cols-1 lg:grid-cols-2 gap-8 mt-8"
      >
        <%!-- Export Column --%>
        <div class="bg-base-100 rounded-lg p-6 border border-base-300">
          <h2 class="text-lg font-semibold mb-2">Export</h2>
          <p class="text-sm text-base-content/70 mb-4">
            Generate a GTFS zip file containing all data from this version. The export includes all required and optional GTFS files with current record counts.
          </p>

          <div class="flex items-center gap-6 mb-6">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="export_type"
                class="radio"
                phx-click="select_export_type"
                phx-value-type="full"
                checked={@export_type == :full}
              />
              <span>Full Export</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="export_type"
                class="radio"
                phx-click="select_export_type"
                phx-value-type="pathways"
                checked={@export_type == :pathways}
              />
              <span>Pathways Export</span>
            </label>
          </div>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>File</th>
                  <th class="text-right">Records</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{filename, count} <- @file_inventory}>
                  <td>{filename}</td>
                  <td class="text-right">{count}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <%= if @export_error do %>
            <div role="alert" class="alert alert-error mt-6">
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
                  d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <span>{@export_error}</span>
            </div>
          <% end %>

          <%= if @exporting do %>
            <button class="btn btn-primary mt-6 w-full" disabled>
              <span class="loading loading-spinner"></span> Exporting...
            </button>
          <% else %>
            <button class="btn btn-primary mt-6 w-full" phx-click="download_export">
              Export GTFS
            </button>
          <% end %>
        </div>

        <%!-- Validate Column --%>
        <div class="bg-base-100 rounded-lg p-6 border border-base-300">
          <h2 class="text-lg font-semibold mb-2">Validate</h2>
          <p class="text-sm text-base-content/70 mb-6">
            Run industry-standard validation checks to ensure data correctness before publishing. Includes MobilityData GTFS Validator and custom pathways trip tests.
          </p>

          <%= if @validation_error do %>
            <div role="alert" class="alert alert-error mb-6">
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
                  d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <span>{@validation_error}</span>
            </div>
          <% end %>

          <%= if @pathways_prep_error do %>
            <div
              id="pathways-prep-error"
              role="alert"
              aria-live="assertive"
              class="alert alert-error alert-soft mb-6"
            >
              <div class="w-full space-y-2 text-base-content">
                <h3 class="font-semibold text-base-content">{@pathways_prep_error.summary}</h3>
                <ul
                  id="pathways-prep-error-details"
                  class="list-disc pl-5 space-y-1 text-base-content"
                >
                  <li :for={issue <- @pathways_prep_error.issues}>{issue.message}</li>
                </ul>
              </div>
            </div>
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
                <div class="grid grid-cols-3 gap-2">
                  <div class="stat p-2 bg-base-200 rounded-lg text-center">
                    <div class="stat-title text-[10px] uppercase opacity-60">Errors</div>
                    <div class="stat-value text-sm text-error">
                      {@validation_result.summary.errors}
                    </div>
                  </div>
                  <div class="stat p-2 bg-base-200 rounded-lg text-center">
                    <div class="stat-title text-[10px] uppercase opacity-60">Warnings</div>
                    <div class="stat-value text-sm text-warning">
                      {@validation_result.summary.warnings}
                    </div>
                  </div>
                  <div class="stat p-2 bg-base-200 rounded-lg text-center">
                    <div class="stat-title text-[10px] uppercase opacity-60">Infos</div>
                    <div class="stat-value text-sm text-info">
                      {@validation_result.summary.infos}
                    </div>
                  </div>
                </div>

                <div class="flex flex-col gap-2">
                  <.link
                    navigate={~p"/gtfs/#{@current_gtfs_version.id}/validation/#{@validation_run_id}"}
                    class="btn btn-primary btn-sm w-full"
                  >
                    View Full Results
                  </.link>
                  <button class="btn btn-outline btn-sm w-full" phx-click="reset_validation">
                    Run Again
                  </button>
                </div>
              </div>
            <% true -> %>
              <div class="space-y-3">
                <label class="flex items-center gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    class="checkbox"
                    phx-click="toggle_validation"
                    phx-value-validation="mobility_data"
                    checked={:mobility_data in @selected_validations}
                  />
                  <div>
                    <div class="font-medium">MobilityData GTFS Validator</div>
                    <div class="text-xs text-base-content/60">
                      Industry-standard validation for GTFS compliance
                    </div>
                  </div>
                </label>

                <label class="flex items-center gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    class="checkbox"
                    phx-click="toggle_validation"
                    phx-value-validation="pathways_tests"
                    checked={:pathways_tests in @selected_validations}
                  />
                  <div>
                    <div class="font-medium">Pathways Trip Tests</div>
                    <div class="text-xs text-base-content/60">
                      Custom validation for pathways connectivity
                    </div>
                  </div>
                </label>
              </div>

              <button class="btn btn-outline mt-6 w-full" phx-click="run_validation">
                Run Validation
              </button>
          <% end %>

          <%!-- Recent Validations --%>
          <%= if @recent_validation_runs != [] do %>
            <div class="mt-8 pt-8 border-t border-base-300">
              <h3 class="text-sm font-semibold mb-4">Recent Validations</h3>
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
                      <td>
                        <.link
                          navigate={~p"/gtfs/#{@current_gtfs_version.id}/validation/#{run.id}"}
                          class="link link-primary"
                        >
                          {format_run_type(run.run_type)}
                        </.link>
                      </td>
                      <td class="text-sm text-base-content/70">
                        {format_date(run.started_at)}
                      </td>
                      <td class={["text-right", run.errors_count > 0 && "text-error font-medium"]}>
                        {run.errors_count}
                      </td>
                      <td class={[
                        "text-right",
                        run.warnings_count > 0 && "text-warning font-medium"
                      ]}>
                        {run.warnings_count}
                      </td>
                      <td class={["text-right", run.infos_count > 0 && "text-info font-medium"]}>
                        {run.infos_count}
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

    <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadHook">
      export default {
        mounted() {
          this.handleEvent("download-file", ({data, filename}) => {
            const blob = new Blob([Uint8Array.from(atob(data), c => c.charCodeAt(0))], {type: "application/zip"});
            const url = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = url;
            a.download = filename;
            a.click();
            URL.revokeObjectURL(url);
          });
        }
      }
    </script>
    """
  end

  defp valid_version_for_org?(version_id, organization_id) do
    try do
      case Versions.get_gtfs_version(version_id) do
        nil -> false
        version -> version.organization_id == organization_id
      end
    rescue
      _ -> false
    end
  end

  defp phase_label(:exporting), do: "Exporting GTFS data..."
  defp phase_label(:validating), do: "Running validator..."
  defp phase_label(:processing), do: "Processing results..."
  defp phase_label({:pathways_prep, :cache_check}), do: "Checking existing export..."
  defp phase_label({:pathways_prep, :preflight}), do: "Validating export readiness..."
  defp phase_label({:pathways_prep, :exporting}), do: "Exporting GTFS data..."
  defp phase_label({:pathways_prep, :packaging}), do: "Packaging GTFS zip..."
  defp phase_label({:pathways_prep, :persisting}), do: "Saving artifact metadata..."
  defp phase_label({:pathways_prep, :done}), do: "Export preparation complete"
  defp phase_label({:pathways_prep, :failed}), do: "Export preparation failed"
  defp phase_label({:pathways_prep, {:gtfs, :cache_check}}), do: "Checking existing export..."
  defp phase_label({:pathways_prep, {:gtfs, :preflight}}), do: "Validating export readiness..."
  defp phase_label({:pathways_prep, {:gtfs, :exporting}}), do: "Exporting GTFS data..."
  defp phase_label({:pathways_prep, {:gtfs, :packaging}}), do: "Packaging GTFS zip..."
  defp phase_label({:pathways_prep, {:gtfs, :persisting}}), do: "Saving artifact metadata..."
  defp phase_label({:pathways_prep, {:gtfs, :done}}), do: "GTFS export preparation complete"
  defp phase_label({:pathways_prep, {:gtfs, :failed}}), do: "GTFS export preparation failed"
  defp phase_label({:pathways_prep, {:graph, :cache_check}}), do: "Checking cached graph..."
  defp phase_label({:pathways_prep, {:graph, :preflight}}), do: "Validating graph build inputs..."
  defp phase_label({:pathways_prep, {:graph, :building}}), do: "Building OTP graph..."
  defp phase_label({:pathways_prep, {:graph, :persisting}}), do: "Saving graph metadata..."
  defp phase_label({:pathways_prep, {:graph, :done}}), do: "Graph preparation complete"
  defp phase_label({:pathways_prep, {:graph, :failed}}), do: "Graph preparation failed"
  defp phase_label(_), do: "Preparing..."

  defp format_run_type("mobility_data"), do: "MobilityData"
  defp format_run_type("pathways_tests"), do: "Pathways Tests"
  defp format_run_type(type), do: type

  defp run_mobility_data_validation(socket, organization_id, gtfs_version_id) do
    case Validations.create_validation_run(organization_id, gtfs_version_id, "mobility_data") do
      {:ok, run} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "validation:#{run.id}")
        end

        validator_module = Application.get_env(:gtfs_planner, :validator_module)

        task =
          Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
            validator_module.validate(organization_id, gtfs_version_id, validation_run_id: run.id)
          end)

        {:noreply,
         socket
         |> assign(:validation_run_id, run.id)
         |> assign(:validation_task, task)
         |> assign(:pathways_prep_task, nil)
         |> assign(:pending_mobility_validation, false)
         |> assign(:validating, true)
         |> assign(:validation_progress, %{phase: :starting, percent: 0})
         |> assign(:validation_result, nil)
         |> assign(:validation_error, nil)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create validation run")}
    end
  end

  defp start_pathways_prep(socket, selected_validations, organization_id, gtfs_version_id) do
    parent = self()
    pending_mobility_validation = Enum.member?(selected_validations, :mobility_data)
    runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module, Runtime)

    task =
      Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
        status_callback = fn payload -> send(parent, {:pathways_prep_progress, payload}) end

        case runtime_module.prepare_runtime(organization_id, gtfs_version_id,
               status_callback: status_callback,
               preflight_mode: :lenient,
               force_rebuild: true
             ) do
          {:ok, _runtime} -> :ok
          {:error, issues} -> {:error, {:pathways_export_prep_failed, issues}}
        end
      end)

    {:noreply,
     socket
     |> assign(:pathways_prep_task, task)
     |> assign(:pending_mobility_validation, pending_mobility_validation)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:pathways_prep_error, nil)
     |> assign(:validating, true)
     |> assign(:validation_progress, %{phase: {:pathways_prep, :cache_check}, percent: 10})}
  end

  defp build_pathways_prep_error(issues) do
    %{
      summary: "Pathways export preparation failed.",
      issues: Enum.map(issues, &format_issue_for_ui/1),
      phase: :pathways_prep,
      log_ref: nil
    }
  end

  defp format_issue_for_ui(%{code: :missing_required_file_data, details: %{file: file}} = issue) do
    %{
      code: issue.code,
      message: "Required GTFS file missing: #{file}",
      details: issue.details
    }
  end

  defp format_issue_for_ui(%{code: :build_failed, details: details} = issue) do
    %{
      code: issue.code,
      message: "OTP graph build failed" <> format_build_detail(details),
      details: details
    }
  end

  defp format_issue_for_ui(issue) do
    %{
      code: issue.code,
      message: issue.message,
      details: issue.details
    }
  end

  defp format_build_detail(details) when is_map(details) do
    labels =
      [
        {"reason_code", Map.get(details, :reason_code) || Map.get(details, "reason_code")},
        {"exit_status", Map.get(details, :exit_status) || Map.get(details, "exit_status")},
        {"build_log_path",
         Map.get(details, :build_log_path) || Map.get(details, "build_log_path")}
      ]
      |> Enum.filter(fn {_label, value} -> not is_nil(value) end)
      |> Enum.map(fn {label, value} -> "#{label}=#{value}" end)

    case labels do
      [] -> ""
      _ -> " (" <> Enum.join(labels, ", ") <> ")"
    end
  end

  defp phase_percent(:cache_check), do: 10
  defp phase_percent(:preflight), do: 25
  defp phase_percent(:exporting), do: 50
  defp phase_percent(:packaging), do: 75
  defp phase_percent(:persisting), do: 90
  defp phase_percent(:done), do: 100
  defp phase_percent(:failed), do: 100
  defp phase_percent({:gtfs, :cache_check}), do: 10
  defp phase_percent({:gtfs, :preflight}), do: 20
  defp phase_percent({:gtfs, :exporting}), do: 35
  defp phase_percent({:gtfs, :packaging}), do: 50
  defp phase_percent({:gtfs, :persisting}), do: 60
  defp phase_percent({:gtfs, :done}), do: 65
  defp phase_percent({:gtfs, :failed}), do: 100
  defp phase_percent({:graph, :cache_check}), do: 70
  defp phase_percent({:graph, :preflight}), do: 75
  defp phase_percent({:graph, :building}), do: 90
  defp phase_percent({:graph, :persisting}), do: 95
  defp phase_percent({:graph, :done}), do: 100
  defp phase_percent({:graph, :failed}), do: 100
  defp phase_percent(_), do: 5

  defp pathways_prep_phase(payload) when is_map(payload) do
    phase = Map.get(payload, :phase, :cache_check)

    case Map.get(payload, :scope) do
      :gtfs -> {:gtfs, phase}
      :graph -> {:graph, phase}
      _unknown_scope -> phase
    end
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end
end
