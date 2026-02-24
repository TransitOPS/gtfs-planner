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

  @pathways_trip_test_poll_interval_ms 250

  @pathways_failure_messages %{
    no_walkability_tests: "No pathways tests are configured for this GTFS version.",
    otp_runtime_failed: "Pathways validation failed during OTP runtime.",
    otp_runtime_already_running:
      "Another pathways runtime is already active for this organization.",
    otp_start_failed: "Failed to start OTP runtime.",
    otp_ready_timeout: "OTP runtime readiness timed out.",
    otp_stop_failed: "OTP runtime failed while stopping.",
    query_failure: "Pathways validation failed due to route query errors.",
    scoring_failure: "Pathways validation failed due to scoring errors.",
    pathways_runner_spawn_failed: "Pathways validation could not start.",
    pathways_trip_test_failed: "Pathways validation failed before OTP checks completed.",
    pathways_persistence_failed: "Pathways validation could not save run results.",
    pathways_export_prep_failed: "Pathways export preparation failed before runtime checks.",
    pathways_task_crashed: "Pathways validation task crashed unexpectedly.",
    pathways_status_unavailable: "Pathways validation status was unavailable.",
    pathways_run_not_found: "Pathways validation run was not found.",
    pathways_invalid_run_type: "Pathways validation run type was invalid.",
    pathways_results_unavailable: "Pathways validation results were unavailable."
  }

  @otp_data_requirements_summary [
    "Station-related stops need valid numeric lat/lon in range.",
    "Longitude sign must match your region (for example, Chicago is negative).",
    "Boarding areas (location_type=4) need a valid parent_station.",
    "Service must be active for the test date and time.",
    "GTFS references must resolve across stops, trips, routes, and service IDs.",
    "Fix critical stop-to-street linking warnings before rerun."
  ]

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
     |> assign(:pathways_prep_detailed_progress, false)
     |> assign(:pending_mobility_validation, false)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:pathways_failure, nil)
     |> assign(:pathways_prep_error, nil)
     |> assign(:export_warnings, [])
     |> assign(:recent_validation_display_counts_by_run_id, %{})
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

    recent_validation_display_counts_by_run_id =
      build_recent_validation_display_counts_map(recent_validation_runs)

    {:noreply,
     socket
     |> assign(:file_inventory, file_inventory)
     |> assign(
       :recent_validation_display_counts_by_run_id,
       recent_validation_display_counts_by_run_id
     )
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
     |> assign(:pathways_prep_detailed_progress, false)
     |> assign(:pending_mobility_validation, false)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:pathways_failure, nil)
     |> assign(:pathways_prep_error, nil)}
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
          export_gtfs_zip(organization_id, gtfs_version_id, export_type)
        end)

      {:noreply,
       socket
       |> assign(:export_task, task)
       |> assign(:exporting, true)
       |> assign(:export_error, nil)
       |> assign(:export_warnings, [])}
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
     socket
     |> assign(:pathways_prep_detailed_progress, true)
     |> assign(:validation_progress, %{
       phase: {:pathways_prep, phase},
       percent: phase_percent(phase)
     })}
  end

  @impl Phoenix.LiveView
  def handle_info({:poll_pathways_trip_test_status, validation_run_id}, socket) do
    if poll_current_pathways_run?(socket, validation_run_id) do
      case Validations.get_pathways_trip_test_status(validation_run_id) do
        {:ok, %{status: "started"}} ->
          schedule_pathways_status_poll(validation_run_id)

          {:noreply, maybe_assign_pathways_status_progress(socket, "started")}

        {:ok, %{status: "running"}} ->
          schedule_pathways_status_poll(validation_run_id)

          {:noreply, maybe_assign_pathways_status_progress(socket, "running")}

        {:ok, %{status: "completed"}} ->
          handle_pathways_trip_test_completed(socket, validation_run_id)

        {:ok, %{status: "failed"} = status_payload} ->
          error_payload =
            payload_value(status_payload, :error_payload) ||
              status_payload

          {:noreply,
           socket
           |> assign(:pending_mobility_validation, false)
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, nil)
           |> assign_pathways_error_panel(error_payload)}

        {:ok, _status_payload} ->
          {:noreply,
           socket
           |> assign(:pending_mobility_validation, false)
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, nil)
           |> assign_pathways_error_panel(%{reason: :pathways_status_unavailable})}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> assign(:pending_mobility_validation, false)
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, nil)
           |> assign_pathways_error_panel(%{reason: :pathways_run_not_found})}

        {:error, :invalid_run_type} ->
          {:noreply,
           socket
           |> assign(:pending_mobility_validation, false)
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, nil)
           |> assign_pathways_error_panel(%{reason: :pathways_invalid_run_type})}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({ref, result}, socket) do
    cond do
      socket.assigns.pathways_prep_task && socket.assigns.pathways_prep_task.ref == ref ->
        Process.demonitor(ref, [:flush])

        socket = assign(socket, :pathways_prep_task, nil)

        case result do
          {:ok, %{run_result: run_result, duration_ms: duration_ms}} ->
            validation_run = Validations.get_validation_run!(socket.assigns.validation_run_id)

            case Validations.mark_pathways_completed(validation_run, run_result, duration_ms) do
              {:ok, completed_run} ->
                persisted_summary =
                  pathways_summary_from_result_json(completed_run.result_json || %{})

                top_failure_categories =
                  pathways_top_failure_categories_from_result_json(
                    completed_run.result_json || %{}
                  )

                socket =
                  socket
                  |> assign(:validation_result, %{
                    run_type: "pathways_tests",
                    pathways_summary: persisted_summary,
                    top_failure_categories: top_failure_categories
                  })
                  |> assign(
                    :recent_validation_runs,
                    Validations.list_recent_validation_runs(
                      socket.assigns.current_organization.id,
                      socket.assigns.current_gtfs_version.id,
                      5
                    )
                  )

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
                   |> assign(:validation_progress, nil)}
                end

              {:error, reason} ->
                _ =
                  maybe_mark_pathways_run_failed(socket, %{
                    reason: :pathways_persistence_failed,
                    details: %{error: inspect(reason)}
                  })

                {:noreply,
                 socket
                 |> assign(:pending_mobility_validation, false)
                 |> assign(:validating, false)
                 |> assign(:validation_progress, nil)
                 |> assign_pathways_error_panel(%{
                   reason: :pathways_persistence_failed,
                   details: %{error: inspect(reason)}
                 })}
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

            _ =
              maybe_mark_pathways_run_failed(socket, %{
                reason: :pathways_export_prep_failed,
                issues: issues
              })

            {:noreply,
             socket
             |> assign(:pending_mobility_validation, false)
             |> assign(:validating, false)
             |> assign(:pathways_prep_detailed_progress, false)
             |> assign(:validation_progress, nil)
             |> assign_pathways_error_panel(%{
               reason: :pathways_export_prep_failed,
               issues: issues
             })}
        end

      socket.assigns.export_task && socket.assigns.export_task.ref == ref ->
        Process.demonitor(ref, [:flush])

        socket =
          case result do
            {:ok, zip_binary, []} ->
              socket
              |> push_gtfs_download(zip_binary)
              |> put_flash(:info, "Export completed successfully")

            {:ok, zip_binary, warnings} when warnings != [] ->
              deduplicated = deduplicate_export_warnings(warnings)

              socket
              |> push_gtfs_download(zip_binary)
              |> put_flash(:info, "Export completed with warnings")
              |> assign(:export_warnings, deduplicated)

            {:ok, zip_binary} ->
              socket
              |> push_gtfs_download(zip_binary)
              |> put_flash(:info, "Export completed successfully")

            {:error, reason} ->
              socket
              |> assign(:export_error, format_export_error(reason))
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

                {:ok, _cleanup_result} ->
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

        _ =
          maybe_mark_pathways_run_failed(socket, %{
            reason: :task_crashed,
            details: %{reason: inspect(reason)}
          })

        {:noreply,
         socket
         |> assign(:validating, false)
         |> assign(:pathways_prep_task, nil)
         |> assign(:pathways_prep_detailed_progress, false)
         |> assign(:pending_mobility_validation, false)
         |> assign(:validation_progress, nil)
         |> assign_pathways_error_panel(%{
           reason: :pathways_task_crashed,
           details: %{reason: inspect(reason)}
         })}

      socket.assigns.export_task && socket.assigns.export_task.ref == ref ->
        Logger.error("Export task crashed: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:export_error, "Export failed. Try again or contact support.")
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
            <p>{issue.message}</p>
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

          <.export_warning_panel :if={@export_warnings != []} export_warnings={@export_warnings} />
        </div>

        <%!-- Validate Column --%>
        <div class="bg-base-100 rounded-lg p-6 border border-base-300">
          <h2 class="text-lg font-semibold mb-2">Validate</h2>
          <p class="text-sm text-base-content/70 mb-6">
            Run industry-standard validation checks to ensure data correctness before publishing. Includes MobilityData GTFS Validator and custom pathways trip tests.
          </p>

          <%= if @validation_error do %>
            <section
              id="validation-error-panel"
              role="alert"
              class="mb-6 rounded-xl border border-error/40 bg-base-100"
            >
              <div class="flex items-start gap-3 border-b border-error/20 px-4 py-3">
                <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 shrink-0 text-error" />
                <div class="min-w-0 flex-1" id="validation-error-content">
                  <%= if @pathways_failure do %>
                    <h3
                      class="text-base font-semibold leading-6 text-base-content"
                      id="pathways-failure-title"
                    >
                      {@pathways_failure.title}
                    </h3>
                    <p
                      class="mt-1 text-sm leading-5 text-base-content/80"
                      id="pathways-failure-summary"
                    >
                      {@pathways_failure.summary}
                    </p>
                    <p
                      class="mt-2 text-sm leading-5 text-base-content/80"
                      id="pathways-failure-status-message"
                    >
                      {@validation_error}
                    </p>
                  <% else %>
                    <p class="text-sm leading-5 text-base-content">{@validation_error}</p>
                  <% end %>
                </div>
              </div>

              <%= if @pathways_failure do %>
                <div class="space-y-4 px-4 py-4 text-sm">
                  <%= if @pathways_failure.blocking_issues != [] do %>
                    <section id="pathways-failure-blocking-issues" class="space-y-2">
                      <h4 class="text-xs font-semibold uppercase tracking-wide text-error">
                        Blocking issues
                      </h4>
                      <ul class="space-y-2">
                        <li
                          :for={issue <- @pathways_failure.blocking_issues}
                          class="border-l-2 border-error/60 pl-3"
                        >
                          <p class="leading-5 text-base-content">{issue.message}</p>
                          <p
                            :if={issue.context_summary}
                            class="mt-1 font-mono text-xs leading-5 text-base-content/70"
                          >
                            {issue.context_summary}
                          </p>
                        </li>
                      </ul>
                    </section>
                  <% end %>

                  <section
                    id="pathways-failure-checks"
                    class="space-y-2 border-t border-base-300 pt-3"
                  >
                    <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                      Recommended checks
                    </h4>
                    <ul class="list-disc space-y-1 pl-5 text-base-content/85">
                      <li :for={check <- @pathways_failure.checks}>{check}</li>
                    </ul>
                  </section>

                  <%= if @pathways_failure.details != [] do %>
                    <section
                      id="pathways-failure-diagnostics"
                      class="space-y-2 border-t border-base-300 pt-3"
                    >
                      <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                        Technical diagnostics
                      </h4>
                      <dl class="divide-y divide-base-300 text-sm text-base-content/85">
                        <div
                          :for={detail <- @pathways_failure.details}
                          class="grid grid-cols-1 gap-1 py-2 sm:grid-cols-[12rem,1fr] sm:gap-3"
                        >
                          <dt class="font-medium text-base-content/80">{detail.label}:</dt>
                          <%= if detail.label == "Build log excerpt" do %>
                            <dd class="rounded border border-base-300 bg-base-200 p-2 font-mono text-xs whitespace-pre-wrap break-words">
                              {detail.value}
                            </dd>
                          <% else %>
                            <dd class="break-all font-mono text-xs sm:text-sm">{detail.value}</dd>
                          <% end %>
                        </div>
                      </dl>
                    </section>
                  <% end %>
                </div>
              <% end %>
            </section>

            <%= if @pathways_failure do %>
              <section
                id="otp-data-requirements-summary"
                class="mb-6 rounded-lg border border-base-300 bg-base-100 p-4"
              >
                <h3 class="text-sm font-semibold text-base-content">
                  OTP data requirements (quick checks)
                </h3>
                <p class="mt-1 text-xs text-base-content/70">
                  Fix these common blockers before rerunning pathways validation.
                </p>
                <ul class="mt-3 list-disc space-y-1 pl-5 text-sm text-base-content/85">
                  <li :for={item <- otp_data_requirements_summary()}>{item}</li>
                </ul>
              </section>
            <% end %>
          <% end %>

          <%= if @pathways_prep_error do %>
            <div role="alert" class="alert alert-error mb-6" id="pathways-prep-error">
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
              <div class="space-y-1">
                <h3 class="font-semibold text-base-content">{@pathways_prep_error.summary}</h3>
                <p class="text-sm text-base-content/80">
                  Fix the issues below, then run validation again.
                </p>

                <%= if @pathways_prep_error.blocking_errors != [] do %>
                  <div class="mt-2" id="pathways-prep-blocking-errors">
                    <h4 class="font-medium text-base-content">Blocking errors</h4>
                    <ul class="list-disc pl-5 text-sm text-base-content/80">
                      <li :for={issue <- @pathways_prep_error.blocking_errors}>{issue.message}</li>
                    </ul>
                  </div>
                <% end %>

                <%= if @pathways_prep_error.warnings != [] do %>
                  <div class="mt-2" id="pathways-prep-warnings">
                    <h4 class="font-medium text-base-content">Warnings</h4>
                    <ul class="list-disc pl-5 text-sm text-base-content/80">
                      <li :for={issue <- @pathways_prep_error.warnings}>{issue.message}</li>
                    </ul>
                  </div>
                <% end %>

                <%= if @pathways_prep_error.blocking_errors == [] and @pathways_prep_error.warnings == [] and
                      @pathways_prep_error.issues != [] do %>
                  <ul
                    class="list-disc pl-5 text-sm text-base-content/80"
                    id="pathways-prep-error-list"
                  >
                    <li :for={issue <- @pathways_prep_error.issues}>{issue.message}</li>
                  </ul>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @pathways_prep_error do %>
            <div role="alert" class="alert alert-error mb-6" id="pathways-prep-error">
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
              <div class="space-y-1">
                <h3 class="font-semibold text-base-content">{@pathways_prep_error.summary}</h3>
                <p class="text-sm text-base-content/80">Fix the issues below, then run validation again.</p>
                <ul class="list-disc pl-5 text-sm text-base-content/80" id="pathways-prep-error-list">
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
                <%= if @validation_result[:run_type] == "pathways_tests" do %>
                  <div class="grid grid-cols-2 gap-2" id="pathways-summary-metrics">
                    <div class="stat p-2 bg-base-200 rounded-lg text-center">
                      <div class="stat-title text-[10px] uppercase opacity-60">Total</div>
                      <div class="stat-value text-sm">
                        {@validation_result.pathways_summary.total}
                      </div>
                    </div>
                    <div class="stat p-2 bg-base-200 rounded-lg text-center">
                      <div class="stat-title text-[10px] uppercase opacity-60">Passed</div>
                      <div class="stat-value text-sm text-success">
                        {@validation_result.pathways_summary.passed}
                      </div>
                    </div>
                    <div class="stat p-2 bg-base-200 rounded-lg text-center">
                      <div class="stat-title text-[10px] uppercase opacity-60">Failed</div>
                      <div class="stat-value text-sm text-error">
                        {@validation_result.pathways_summary.failed}
                      </div>
                    </div>
                    <div class="stat p-2 bg-base-200 rounded-lg text-center">
                      <div class="stat-title text-[10px] uppercase opacity-60">Pass Rate</div>
                      <div class="stat-value text-sm">
                        {@validation_result.pathways_summary.pass_rate}%
                      </div>
                    </div>
                  </div>

                  <%= if @validation_result.top_failure_categories != [] do %>
                    <div class="space-y-2" id="pathways-top-failure-categories">
                      <h3 class="text-xs font-semibold uppercase opacity-60">
                        Top Failure Categories
                      </h3>
                      <ul class="space-y-1 text-sm">
                        <li :for={category <- @validation_result.top_failure_categories}>
                          {category.category}: {category.count}
                        </li>
                      </ul>
                    </div>
                  <% end %>
                <% else %>
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
                <% end %>

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
                      <% display_counts =
                        Map.get(
                          @recent_validation_display_counts_by_run_id,
                          run.id,
                          recent_validation_display_counts(run)
                        ) %>
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
                      <td
                        id={"recent-validation-errors-#{run.id}"}
                        class={[
                          "text-right",
                          display_counts.errors > 0 && "text-error font-medium"
                        ]}
                      >
                        {display_counts.errors}
                      </td>
                      <td
                        id={"recent-validation-warnings-#{run.id}"}
                        class={[
                          "text-right",
                          display_counts.warnings > 0 && "text-warning font-medium"
                        ]}
                      >
                        {display_counts.warnings}
                      </td>
                      <td
                        id={"recent-validation-infos-#{run.id}"}
                        class={[
                          "text-right",
                          display_counts.infos > 0 && "text-info font-medium"
                        ]}
                      >
                        {display_counts.infos}
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
  defp phase_label({:pathways_prep, {:otp, :starting}}), do: "Starting OTP runtime..."
  defp phase_label({:pathways_prep, {:otp, :waiting_ready}}), do: "Waiting for OTP readiness..."
  defp phase_label({:pathways_prep, {:otp, :ready}}), do: "Running OTP validity checks..."
  defp phase_label({:pathways_prep, {:otp, :stopping}}), do: "Stopping OTP runtime..."
  defp phase_label({:pathways_prep, {:otp, :stopped}}), do: "OTP runtime stopped"
  defp phase_label({:pathways_prep, {:otp, :failed}}), do: "OTP runtime failed"

  defp phase_label({:pathways_prep, {:suite, :running, completed, total, _test_case_id}}),
    do: "Running pathways suite (#{completed} of #{total})"

  defp phase_label({:pathways_prep, {:suite, :finishing, _completed, _total, _test_case_id}}),
    do: "Finalizing pathways suite results..."

  defp phase_label({:pathways_prep, {:suite, :finished, _completed, _total, _test_case_id}}),
    do: "Pathways suite finished"

  defp phase_label({:pathways_prep, :running}), do: "Running pathways trip test..."

  defp phase_label(_), do: "Preparing..."

  defp format_run_type("mobility_data"), do: "MobilityData"
  defp format_run_type("pathways_tests"), do: "Pathways Tests"
  defp format_run_type(type), do: type

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
      {run.id, recent_validation_display_counts_from_source(run)}
    end)
    |> Map.new()
  end

  defp recent_validation_display_counts_from_source(%{run_type: "pathways_tests"} = run) do
    case Validations.get_pathways_trip_test_results(run.id) do
      {:ok, %{walkability_test_run_results: walkability_test_run_results}} ->
        pathways_recent_validation_display_counts(walkability_test_run_results)

      {:error, _reason} ->
        recent_validation_display_counts(run)
    end
  end

  defp recent_validation_display_counts_from_source(run),
    do: recent_validation_display_counts(run)

  defp pathways_recent_validation_display_counts(walkability_test_run_results)
       when is_list(walkability_test_run_results) do
    {errors, warnings} =
      Enum.reduce(walkability_test_run_results, {0, 0}, fn row, {errors, warnings} ->
        case pathways_case_display_status_for_recent_row(row) do
          "failed" -> {errors + 1, warnings}
          "warning" -> {errors, warnings + 1}
          _status -> {errors, warnings}
        end
      end)

    %{
      errors: errors,
      warnings: warnings,
      infos: 0
    }
  end

  defp pathways_recent_validation_display_counts(_walkability_test_run_results) do
    %{errors: 0, warnings: 0, infos: 0}
  end

  defp pathways_case_display_status_for_recent_row(row) do
    mismatch_map = pathways_recent_mismatch_map(Map.get(row, :details_json))

    traversable_failed? = Map.has_key?(mismatch_map, "expected_traversable")

    other_criteria_failed? =
      mismatch_map
      |> Map.drop(["expected_traversable"])
      |> map_has_entries?()

    cond do
      row.failure_category == "query_failure" -> "failed"
      traversable_failed? -> "failed"
      other_criteria_failed? -> "warning"
      true -> "pass"
    end
  end

  defp pathways_recent_mismatch_map(details_json) when is_map(details_json) do
    details_json
    |> payload_value(:mismatches)
    |> pathways_recent_ensure_list()
    |> Enum.reduce(%{}, fn mismatch, acc ->
      case pathways_recent_mismatch_kind(mismatch) do
        nil -> acc
        kind -> Map.put(acc, kind, mismatch)
      end
    end)
  end

  defp pathways_recent_mismatch_map(_details_json), do: %{}

  defp pathways_recent_ensure_list(value) when is_list(value), do: value
  defp pathways_recent_ensure_list(_value), do: []

  defp pathways_recent_mismatch_kind(mismatch) when is_map(mismatch) do
    case payload_value(mismatch, :kind) do
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind when is_binary(kind) -> kind
      _ -> nil
    end
  end

  defp pathways_recent_mismatch_kind(_mismatch), do: nil

  defp map_has_entries?(map) when is_map(map), do: map_size(map) > 0
  defp map_has_entries?(_map), do: false

  defp pathways_summary_from_result_json(result_json) do
    summary = Map.get(result_json, "summary", %{})

    %{
      total: Map.get(summary, "total", 0),
      passed: Map.get(summary, "passed", 0),
      failed: Map.get(summary, "failed", 0),
      pass_rate: Map.get(summary, "pass_rate", 0.0)
    }
  end

  defp pathways_top_failure_categories_from_result_json(result_json) do
    result_json
    |> Map.get("top_failure_categories", [])
    |> Enum.map(fn category ->
      %{
        category: Map.get(category, "category", "unknown"),
        count: Map.get(category, "count", 0)
      }
    end)
  end

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
         |> assign(:validation_error, nil)
         |> assign(:pathways_failure, nil)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create validation run")}
    end
  end

  defp start_pathways_prep(socket, selected_validations, organization_id, gtfs_version_id) do
    parent = self()
    pending_mobility_validation = Enum.member?(selected_validations, :mobility_data)
    runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module, Runtime)

    start_new_pathways_prep(socket, pending_mobility_validation, organization_id, gtfs_version_id)
  end

  defp start_new_pathways_prep(
         socket,
         pending_mobility_validation,
         organization_id,
         gtfs_version_id
       ) do
    live_view_pid = self()

    case Validations.start_pathways_trip_test(organization_id, gtfs_version_id,
           status_callback: pathways_prep_status_callback(live_view_pid)
         ) do
      {:ok, run} ->
        send(self(), {:poll_pathways_trip_test_status, run.id})

        {:noreply,
         socket
         |> assign(:validation_run_id, run.id)
         |> assign(:pathways_prep_task, nil)
         |> assign(:pathways_prep_detailed_progress, false)
         |> assign(:pending_mobility_validation, pending_mobility_validation)
         |> assign(:validation_result, nil)
         |> assign(:validation_error, nil)
         |> assign(:pathways_failure, nil)
         |> assign(:pathways_prep_error, nil)
         |> assign(:validating, true)
         |> assign(:validation_progress, pathways_status_progress(run.status))}

      {:error, {:pathways_runner_spawn_failed, reason}} ->
        {:noreply,
         socket
         |> assign(:pending_mobility_validation, false)
         |> assign(:validating, false)
         |> assign(:pathways_prep_detailed_progress, false)
         |> assign(:validation_progress, nil)
         |> assign_pathways_error_panel(%{
           reason: :pathways_runner_spawn_failed,
           details: %{error: inspect(reason)}
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:pending_mobility_validation, false)
         |> assign(:validating, false)
         |> assign(:pathways_prep_detailed_progress, false)
         |> assign(:validation_progress, nil)
         |> assign_pathways_error_panel(%{
           reason: :pathways_trip_test_failed,
           details: %{error: inspect(reason)}
         })}
    end
  end

  defp pathways_prep_status_callback(live_view_pid) do
    fn payload ->
      send(live_view_pid, {:pathways_prep_progress, payload})
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
  defp phase_percent({:graph, :done}), do: 96
  defp phase_percent({:graph, :failed}), do: 100
  defp phase_percent({:otp, :starting}), do: 96
  defp phase_percent({:otp, :waiting_ready}), do: 97
  defp phase_percent({:otp, :ready}), do: 98
  defp phase_percent({:otp, :stopping}), do: 99
  defp phase_percent({:otp, :stopped}), do: 100
  defp phase_percent({:otp, :failed}), do: 100
  defp phase_percent({:suite, :running, _completed, _total, _test_case_id}), do: 98
  defp phase_percent({:suite, :finishing, _completed, _total, _test_case_id}), do: 99
  defp phase_percent({:suite, :finished, _completed, _total, _test_case_id}), do: 100
  defp phase_percent(_), do: 5

  defp pathways_prep_phase(payload) when is_map(payload) do
    phase = Map.get(payload, :phase, :cache_check)
    completed = Map.get(payload, :completed)
    total = Map.get(payload, :total)
    test_case_id = Map.get(payload, :test_case_id)

    case Map.get(payload, :scope) do
      :gtfs -> {:gtfs, phase}
      :graph -> {:graph, phase}
      :otp -> {:otp, phase}
      :suite -> {:suite, phase, completed, total, test_case_id}
      _unknown_scope -> phase
    end
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  defp poll_current_pathways_run?(socket, validation_run_id) do
    socket.assigns[:validating] && socket.assigns[:validation_run_id] == validation_run_id
  end

  defp schedule_pathways_status_poll(validation_run_id) do
    Process.send_after(
      self(),
      {:poll_pathways_trip_test_status, validation_run_id},
      @pathways_trip_test_poll_interval_ms
    )
  end

  defp pathways_status_progress("started"),
    do: %{phase: {:pathways_prep, :cache_check}, percent: 10}

  defp pathways_status_progress("running"),
    do: %{phase: {:pathways_prep, :running}, percent: 50}

  defp pathways_status_progress(_status), do: %{phase: :processing, percent: 95}

  defp maybe_assign_pathways_status_progress(socket, status) do
    if socket.assigns.pathways_prep_detailed_progress do
      socket
    else
      assign(socket, :validation_progress, pathways_status_progress(status))
    end
  end

  defp handle_pathways_trip_test_completed(socket, validation_run_id) do
    case Validations.get_pathways_trip_test_results(validation_run_id) do
      {:ok, result_payload} ->
        persisted_summary = pathways_summary_from_result_json(result_payload.result_json || %{})

        top_failure_categories =
          pathways_top_failure_categories_from_result_json(result_payload.result_json || %{})

        socket =
          socket
          |> assign(:validation_result, %{
            run_type: "pathways_tests",
            pathways_summary: persisted_summary,
            top_failure_categories: top_failure_categories
          })
          |> assign(
            :recent_validation_runs,
            Validations.list_recent_validation_runs(
              socket.assigns.current_organization.id,
              socket.assigns.current_gtfs_version.id,
              5
            )
          )

        if socket.assigns.pending_mobility_validation do
          run_mobility_data_validation(
            socket
            |> assign(:pending_mobility_validation, false)
            |> assign(:validating, false)
            |> assign(:pathways_prep_detailed_progress, false)
            |> assign(:validation_progress, nil),
            socket.assigns.current_organization.id,
            socket.assigns.current_gtfs_version.id
          )
        else
          {:noreply,
           socket
           |> assign(:pending_mobility_validation, false)
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, nil)}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:pending_mobility_validation, false)
         |> assign(:validating, false)
         |> assign(:pathways_prep_detailed_progress, false)
         |> assign(:validation_progress, nil)
         |> assign_pathways_error_panel(%{
           reason: :pathways_results_unavailable,
           details: %{error: inspect(reason)}
         })}
    end
  end

  defp pathways_failure_message(error_payload) when is_map(error_payload) do
    base_message =
      error_payload
      |> pathways_failure_tokens()
      |> Enum.find_value(&normalize_pathways_failure_code/1)
      |> case do
        nil ->
          "Pathways validation failed"

        failure_code ->
          Map.get(@pathways_failure_messages, failure_code, "Pathways validation failed")
      end

    case pathways_failure_diagnostic(error_payload) do
      nil -> base_message
      diagnostic -> base_message <> " " <> diagnostic
    end
  end

  defp pathways_failure_message(_error_payload), do: "Pathways validation failed"

  @doc false
  @spec classify_pathways_failure_category(map()) ::
          :no_walkability_tests
          | :pathways_startup_failure
          | :pathways_run_unavailable
          | :pathways_internal_failure
          | :csv_parse_malformed_rows
          | :invalid_coordinates
          | :boarding_area_parent_integrity
          | :osm_coverage_stop_linking
          | :service_window_inactive
          | :referential_integrity
          | :missing_corrupt_files_or_permissions
          | :java_heap_runtime_compatibility
          | :unknown_build_failure
  def classify_pathways_failure_category(error_payload) when is_map(error_payload) do
    tokens = pathways_failure_classifier_tokens(error_payload)

    failure_code =
      error_payload
      |> pathways_failure_tokens()
      |> Enum.find_value(&normalize_pathways_failure_code/1)

    cond do
      failure_code == :no_walkability_tests ->
        :no_walkability_tests

      failure_code in [
        :pathways_runner_spawn_failed,
        :pathways_trip_test_failed
      ] ->
        :pathways_startup_failure

      failure_code in [
        :pathways_status_unavailable,
        :pathways_run_not_found,
        :pathways_invalid_run_type,
        :pathways_results_unavailable
      ] ->
        :pathways_run_unavailable

      failure_code in [
        :pathways_persistence_failed,
        :pathways_export_prep_failed,
        :pathways_task_crashed
      ] ->
        :pathways_internal_failure

      tokens_match_any?(tokens, ["csv", "parse", "malformed", "invalid row"]) ->
        :csv_parse_malformed_rows

      tokens_match_any?(tokens, [
        "invalid coordinate",
        "latitude",
        "longitude",
        "outside bounds",
        "out-of-range",
        "sign-flipped"
      ]) ->
        :invalid_coordinates

      tokens_match_any?(tokens, [
        "boarding area",
        "boarding_area",
        "location_type=4",
        "parent_station"
      ]) ->
        :boarding_area_parent_integrity

      tokens_match_any?(tokens, ["osm", "stop linking", "linking failed", "outside osm"]) ->
        :osm_coverage_stop_linking

      tokens_match_any?(tokens, [
        "service window",
        "no active service",
        "calendar",
        "inactive service"
      ]) ->
        :service_window_inactive

      tokens_match_any?(tokens, [
        "referential",
        "orphan",
        "missing stop_id",
        "missing route_id",
        "missing service_id",
        "foreign key"
      ]) ->
        :referential_integrity

      tokens_match_any?(tokens, [
        "missing file",
        "corrupt",
        "permission denied",
        "basepath",
        "enoent",
        "eacces",
        "unreadable"
      ]) ->
        :missing_corrupt_files_or_permissions

      tokens_match_any?(tokens, [
        "outofmemoryerror",
        "java heap space",
        "unsupported class file major version",
        "java runtime",
        "jvm"
      ]) ->
        :java_heap_runtime_compatibility

      true ->
        :unknown_build_failure
    end
  end

  def classify_pathways_failure_category(_error_payload), do: :unknown_build_failure

  @doc false
  @spec present_pathways_failure(category :: atom(), error_payload :: map() | term()) :: %{
          category: atom(),
          title: String.t(),
          summary: String.t(),
          checks: [String.t()],
          details: [%{label: String.t(), value: String.t()}]
        }
  def present_pathways_failure(category, error_payload)
      when is_atom(category) and is_map(error_payload) do
    {title, summary, checks} = pathways_failure_copy(category)

    %{
      category: category,
      title: title,
      summary: summary,
      checks: checks,
      details: pathways_failure_presenter_details(error_payload),
      blocking_issues: pathways_failure_blocking_issues(error_payload)
    }
  end

  def present_pathways_failure(category, _error_payload) when is_atom(category) do
    {title, summary, checks} = pathways_failure_copy(category)

    %{
      category: category,
      title: title,
      summary: summary,
      checks: checks,
      details: [],
      blocking_issues: []
    }
  end

  defp pathways_failure_blocking_issues(error_payload) do
    error_payload
    |> payload_value(:issues)
    |> normalize_pathways_failure_issues()
    |> Enum.filter(&(&1.severity in [:blocking, :error]))
  end

  defp normalize_pathways_failure_issues(issues) when is_list(issues) do
    Enum.map(issues, &normalize_pathways_failure_issue/1)
  end

  defp normalize_pathways_failure_issues(_issues), do: []

  defp normalize_pathways_failure_issue(issue) when is_map(issue) do
    code = payload_value(issue, :code) || :pathways_preflight_blocking_issue

    context =
      issue
      |> payload_value(:context)
      |> case do
        context when is_map(context) ->
          context

        _other ->
          case payload_value(issue, :details) do
            details when is_map(details) -> details
            _details -> %{}
          end
      end

    message =
      case payload_value(issue, :message) do
        message when is_binary(message) and message != "" -> message
        _other -> pathways_failure_issue_fallback_message(code, context)
      end

    %{
      code: code,
      severity: normalize_pathways_failure_issue_severity(payload_value(issue, :severity)),
      message: message,
      context_summary: pathways_failure_issue_context_summary(context)
    }
  end

  defp normalize_pathways_failure_issue(issue) do
    %{
      code: :pathways_preflight_invalid_issue,
      severity: :blocking,
      message: "Pathways preflight returned malformed issue payload.",
      context_summary: inspect(issue)
    }
  end

  defp normalize_pathways_failure_issue_severity(:warning), do: :warning
  defp normalize_pathways_failure_issue_severity(:info), do: :info
  defp normalize_pathways_failure_issue_severity(:error), do: :error
  defp normalize_pathways_failure_issue_severity("warning"), do: :warning
  defp normalize_pathways_failure_issue_severity("info"), do: :info
  defp normalize_pathways_failure_issue_severity("error"), do: :error
  defp normalize_pathways_failure_issue_severity(_severity), do: :blocking

  defp pathways_failure_issue_fallback_message(code, context) do
    file = payload_value(context, :file)
    field = payload_value(context, :field)

    cond do
      is_binary(file) and is_binary(field) ->
        "Check #{field} in #{file} and rerun pathways validation."

      is_binary(file) ->
        "Check #{file} for #{code} and rerun pathways validation."

      true ->
        "Resolve #{code} and rerun pathways validation."
    end
  end

  defp pathways_failure_issue_context_summary(context) when is_map(context) do
    [:file, :field, :stop_id, :trip_id, :route_id, :service_id, :pathway_id, :value]
    |> Enum.map(fn key ->
      case payload_value(context, key) do
        nil -> nil
        "" -> nil
        value -> "#{key}: #{value}"
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      items -> Enum.join(items, " • ")
    end
  end

  defp pathways_failure_issue_context_summary(_context), do: nil

  defp present_pathways_failure_for_payload(error_payload) when is_map(error_payload) do
    error_payload
    |> classify_pathways_failure_category()
    |> present_pathways_failure(error_payload)
  end

  defp present_pathways_failure_for_payload(_error_payload) do
    present_pathways_failure(:unknown_build_failure, %{})
  end

  defp pathways_failure_copy(:csv_parse_malformed_rows) do
    {
      "CSV rows are malformed",
      "OTP could not parse one or more GTFS rows while building pathways data.",
      [
        "Open pathways.txt and related files and fix malformed rows.",
        "Confirm required columns are present and values use valid formats."
      ]
    }
  end

  defp pathways_failure_copy(:no_walkability_tests) do
    {
      "No pathways tests configured",
      "This GTFS version has no walkability test rows to execute.",
      [
        "Add at least one pathways test for this GTFS version.",
        "Verify test rows include a valid stop_id and address coordinates."
      ]
    }
  end

  defp pathways_failure_copy(:pathways_startup_failure) do
    {
      "Pathways test run could not start",
      "The pathways run failed before OTP checks could execute.",
      [
        "Retry validation to create a fresh run.",
        "If this repeats, review runner and task-supervisor logs."
      ]
    }
  end

  defp pathways_failure_copy(:pathways_run_unavailable) do
    {
      "Pathways run status unavailable",
      "The run state could not be retrieved for this pathways validation.",
      [
        "Refresh and retry the pathways validation.",
        "If the issue repeats, check validation run persistence and polling logs."
      ]
    }
  end

  defp pathways_failure_copy(:pathways_internal_failure) do
    {
      "Pathways validation internal failure",
      "The run failed due to an internal preparation or persistence issue.",
      [
        "Review technical diagnostics and resolve the first blocking issue.",
        "Retry validation after fixing preparation or persistence errors."
      ]
    }
  end

  defp pathways_failure_copy(:invalid_coordinates) do
    {
      "Invalid stop or pathway coordinates",
      "OTP rejected coordinates that are out of bounds or incorrectly signed.",
      [
        "Verify latitude and longitude values for stops and pathways.",
        "Confirm longitude signs are correct for your service area."
      ]
    }
  end

  defp pathways_failure_copy(:boarding_area_parent_integrity) do
    {
      "Boarding area parent data is invalid",
      "Some boarding areas are missing valid parent station references.",
      [
        "Ensure each location_type=4 stop has a valid parent_station.",
        "Confirm parent stations exist and are in the same feed version."
      ]
    }
  end

  defp pathways_failure_copy(:osm_coverage_stop_linking) do
    {
      "Stops could not link to OSM pathways",
      "OTP could not link one or more stops to the street graph.",
      [
        "Verify stops are within the area covered by your OSM extract.",
        "Check stop coordinates for placement errors near streets."
      ]
    }
  end

  defp pathways_failure_copy(:service_window_inactive) do
    {
      "No active service window",
      "Pathways testing could not find active service for the selected period.",
      [
        "Review calendar.txt and calendar_dates.txt for active service.",
        "Confirm test dates overlap valid service windows."
      ]
    }
  end

  defp pathways_failure_copy(:referential_integrity) do
    {
      "GTFS references are inconsistent",
      "OTP found missing or orphaned references across GTFS files.",
      [
        "Check that referenced stop_id, route_id, and service_id values exist.",
        "Fix orphan rows and rerun pathways validation."
      ]
    }
  end

  defp pathways_failure_copy(:missing_corrupt_files_or_permissions) do
    {
      "Build inputs are missing or unreadable",
      "OTP could not read required files due to missing, corrupt, or permission issues.",
      [
        "Confirm required files exist and are not corrupt.",
        "Verify file and directory permissions for the OTP build path."
      ]
    }
  end

  defp pathways_failure_copy(:java_heap_runtime_compatibility) do
    {
      "Java runtime or memory issue",
      "OTP failed due to Java compatibility or heap memory limits.",
      [
        "Verify the configured Java runtime version is supported.",
        "Increase JVM heap size and retry the graph build."
      ]
    }
  end

  defp pathways_failure_copy(_unknown_category) do
    {
      "OTP pathways build failed",
      "OTP reported a build or runtime failure while preparing pathways validation.",
      [
        "Review OTP diagnostics below and fix the first blocking issue.",
        "Rerun pathways validation after data and runtime updates."
      ]
    }
  end

  defp pathways_failure_presenter_details(error_payload) do
    root_details = payload_value(error_payload, :details)
    issue_codes = pathways_failure_issue_codes(error_payload)
    build_log_path = pathways_failure_build_log_path(error_payload)
    build_log_excerpt = pathways_failure_build_log_excerpt(error_payload)
    build_log_gtfs_source = pathways_failure_build_log_gtfs_source(build_log_excerpt)
    build_log_npe_hint = pathways_failure_npe_parent_station_hint(build_log_excerpt)

    [
      presenter_detail("Reason", payload_value(error_payload, :reason)),
      presenter_detail("Reason code", payload_value(root_details, :reason_code)),
      presenter_detail("Issue codes", issue_codes),
      presenter_detail("Exit status", pathways_failure_exit_status(error_payload)),
      presenter_detail("Build log path", build_log_path),
      presenter_detail("Build log excerpt", build_log_excerpt),
      presenter_detail("Likely GTFS source", build_log_gtfs_source),
      presenter_detail("Likely cause", build_log_npe_hint)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp pathways_failure_issue_codes(error_payload) do
    error_payload
    |> payload_value(:issues)
    |> case do
      issues when is_list(issues) ->
        issues
        |> Enum.map(&payload_value(&1, :code))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string/1)
        |> Enum.join(", ")

      _other ->
        nil
    end
  end

  defp pathways_failure_exit_status(error_payload) do
    case pathways_build_failure_reason_code(error_payload) do
      :build_command_failed ->
        error_payload
        |> pathways_build_failure_details()
        |> payload_value(:exit_status)
        |> case do
          nil ->
            error_payload
            |> payload_value(:details)
            |> payload_value(:exit_status)

          exit_status ->
            exit_status
        end

      _other ->
        nil
    end
  end

  defp pathways_failure_build_log_path(error_payload) do
    case pathways_build_failure_reason_code(error_payload) do
      :build_command_failed ->
        error_payload
        |> pathways_build_failure_details()
        |> payload_value(:build_log_path)
        |> case do
          nil ->
            error_payload
            |> payload_value(:details)
            |> payload_value(:build_log_path)

          build_log_path ->
            build_log_path
        end

      _other ->
        nil
    end
  end

  defp pathways_failure_build_log_excerpt(error_payload) do
    case pathways_failure_build_log_path(error_payload) do
      nil ->
        nil

      build_log_path ->
        extract_build_log_excerpt(build_log_path)
    end
  end

  defp pathways_failure_build_log_gtfs_source(nil), do: nil

  defp pathways_failure_build_log_gtfs_source(build_log_excerpt)
       when is_binary(build_log_excerpt) do
    case extract_gtfs_txt_filename(build_log_excerpt) do
      nil ->
        nil

      filename ->
        "Issue appears to come from #{filename}."
    end
  end

  defp pathways_failure_build_log_gtfs_source(_build_log_excerpt), do: nil

  defp pathways_failure_npe_parent_station_hint(nil), do: nil

  defp pathways_failure_npe_parent_station_hint(build_log_excerpt)
       when is_binary(build_log_excerpt) do
    if String.contains?(build_log_excerpt, "NullPointerException") do
      "NullPointerException often indicates a child stop is missing a valid parent_station assignment."
    else
      nil
    end
  end

  defp pathways_failure_npe_parent_station_hint(_build_log_excerpt), do: nil

  defp extract_gtfs_txt_filename(text) when is_binary(text) do
    case Regex.run(~r/\b([A-Za-z0-9_.-]+\.txt)\b/i, text, capture: :all_but_first) do
      [filename] -> filename
      _ -> nil
    end
  end

  defp extract_gtfs_txt_filename(_text), do: nil

  defp extract_build_log_excerpt(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> build_log_excerpt_from_body()

      {:error, _reason} ->
        nil
    end
  end

  defp extract_build_log_excerpt(_path), do: nil

  defp build_log_excerpt_from_body(body) when is_binary(body) do
    lines =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)

    highlighted =
      Enum.filter(lines, fn line ->
        String.contains?(line, "ERROR") or
          String.contains?(line, "Exception") or
          String.contains?(line, "Caused by")
      end)

    excerpt_lines =
      case highlighted do
        [] ->
          lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(-8)

        _ ->
          highlighted
          |> Enum.take(8)
      end

    case excerpt_lines do
      [] -> nil
      _lines -> Enum.join(excerpt_lines, "\n")
    end
  end

  defp pathways_build_failure_reason_code(error_payload) do
    issue_reason_code =
      error_payload
      |> pathways_build_failure_details()
      |> payload_value(:reason_code)

    root_reason_code =
      error_payload
      |> payload_value(:details)
      |> payload_value(:reason_code)

    case issue_reason_code || root_reason_code do
      :build_command_failed -> :build_command_failed
      "build_command_failed" -> :build_command_failed
      _other -> nil
    end
  end

  defp pathways_build_failure_details(error_payload) do
    error_payload
    |> payload_value(:issues)
    |> case do
      issues when is_list(issues) ->
        Enum.find_value(issues, fn issue ->
          details = payload_value(issue, :details)

          case payload_value(details, :reason_code) do
            :build_command_failed -> details
            "build_command_failed" -> details
            _other -> nil
          end
        end)

      _other ->
        nil
    end
  end

  defp presenter_detail(_label, nil), do: nil
  defp presenter_detail(_label, ""), do: nil

  defp presenter_detail(label, value) do
    %{label: label, value: presenter_detail_value(value)}
  end

  defp presenter_detail_value(value) when is_binary(value), do: value
  defp presenter_detail_value(value) when is_atom(value), do: Atom.to_string(value)
  defp presenter_detail_value(value) when is_integer(value), do: Integer.to_string(value)
  defp presenter_detail_value(value), do: inspect(value)

  defp pathways_failure_tokens(error_payload) do
    reason = payload_value(error_payload, :reason)

    details_reason =
      error_payload
      |> payload_value(:details)
      |> payload_value(:reason)

    issue_codes =
      error_payload
      |> payload_value(:issues)
      |> issue_code_tokens()

    [reason, details_reason | issue_codes]
  end

  defp pathways_failure_classifier_tokens(error_payload) do
    root_details = payload_value(error_payload, :details)

    issue_tokens =
      error_payload
      |> payload_value(:issues)
      |> pathways_failure_issue_classifier_tokens()

    [
      payload_value(error_payload, :reason),
      payload_value(error_payload, :raw_error_details),
      payload_value(root_details, :reason),
      payload_value(root_details, :reason_code),
      payload_value(root_details, :message)
      | issue_tokens
    ]
    |> Enum.map(&normalize_failure_classifier_token/1)
    |> Enum.reject(&is_nil/1)
  end

  defp pathways_failure_issue_classifier_tokens(issues) when is_list(issues) do
    Enum.flat_map(issues, fn issue ->
      details = payload_value(issue, :details)

      [
        payload_value(issue, :code),
        payload_value(issue, :reason),
        payload_value(issue, :reason_code),
        payload_value(issue, :message),
        payload_value(details, :reason),
        payload_value(details, :reason_code),
        payload_value(details, :message)
      ]
    end)
  end

  defp pathways_failure_issue_classifier_tokens(_issues), do: []

  defp normalize_failure_classifier_token(nil), do: nil
  defp normalize_failure_classifier_token(value) when is_binary(value), do: String.downcase(value)

  defp normalize_failure_classifier_token(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.downcase()

  defp normalize_failure_classifier_token(value),
    do: value |> inspect() |> String.downcase()

  defp tokens_match_any?(tokens, fragments) do
    Enum.any?(tokens, fn token ->
      Enum.any?(fragments, &String.contains?(token, &1))
    end)
  end

  defp issue_code_tokens(issues) when is_list(issues),
    do: Enum.map(issues, &payload_value(&1, :code))

  defp issue_code_tokens(_issues), do: []

  defp payload_value(nil, _key), do: nil

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  defp normalize_pathways_failure_code(:no_walkability_tests), do: :no_walkability_tests

  defp normalize_pathways_failure_code(:otp_runtime_already_running),
    do: :otp_runtime_already_running

  defp normalize_pathways_failure_code(:otp_start_failed), do: :otp_start_failed
  defp normalize_pathways_failure_code(:otp_runtime_failed), do: :otp_runtime_failed
  defp normalize_pathways_failure_code(:otp_ready_timeout), do: :otp_ready_timeout
  defp normalize_pathways_failure_code(:otp_stop_failed), do: :otp_stop_failed
  defp normalize_pathways_failure_code(:query_failure), do: :query_failure
  defp normalize_pathways_failure_code(:scoring_failure), do: :scoring_failure

  defp normalize_pathways_failure_code(:pathways_runner_spawn_failed),
    do: :pathways_runner_spawn_failed

  defp normalize_pathways_failure_code(:pathways_trip_test_failed), do: :pathways_trip_test_failed

  defp normalize_pathways_failure_code(:pathways_persistence_failed),
    do: :pathways_persistence_failed

  defp normalize_pathways_failure_code(:pathways_export_prep_failed),
    do: :pathways_export_prep_failed

  defp normalize_pathways_failure_code(:pathways_task_crashed), do: :pathways_task_crashed

  defp normalize_pathways_failure_code(:pathways_status_unavailable),
    do: :pathways_status_unavailable

  defp normalize_pathways_failure_code(:pathways_run_not_found), do: :pathways_run_not_found
  defp normalize_pathways_failure_code(:pathways_invalid_run_type), do: :pathways_invalid_run_type

  defp normalize_pathways_failure_code(:pathways_results_unavailable),
    do: :pathways_results_unavailable

  defp normalize_pathways_failure_code(value) when is_binary(value) do
    case value do
      "no_walkability_tests" ->
        :no_walkability_tests

      "otp_runtime_already_running" ->
        :otp_runtime_already_running

      "otp_start_failed" ->
        :otp_start_failed

      "otp_runtime_failed" ->
        :otp_runtime_failed

      "otp_ready_timeout" ->
        :otp_ready_timeout

      "otp_stop_failed" ->
        :otp_stop_failed

      "query_failure" ->
        :query_failure

      "scoring_failure" ->
        :scoring_failure

      "pathways_runner_spawn_failed" ->
        :pathways_runner_spawn_failed

      "pathways_trip_test_failed" ->
        :pathways_trip_test_failed

      "pathways_persistence_failed" ->
        :pathways_persistence_failed

      "pathways_export_prep_failed" ->
        :pathways_export_prep_failed

      "pathways_task_crashed" ->
        :pathways_task_crashed

      "pathways_status_unavailable" ->
        :pathways_status_unavailable

      "pathways_run_not_found" ->
        :pathways_run_not_found

      "pathways_invalid_run_type" ->
        :pathways_invalid_run_type

      "pathways_results_unavailable" ->
        :pathways_results_unavailable

      _other ->
        normalize_pathways_failure_code_from_text(value)
    end
  end

  defp normalize_pathways_failure_code(_value), do: nil

  defp normalize_pathways_failure_code_from_text(value) when is_binary(value) do
    cond do
      String.contains?(value, "no_walkability_tests") -> :no_walkability_tests
      String.contains?(value, "otp_runtime_already_running") -> :otp_runtime_already_running
      String.contains?(value, "otp_start_failed") -> :otp_start_failed
      String.contains?(value, "otp_runtime_failed") -> :otp_runtime_failed
      String.contains?(value, "otp_ready_timeout") -> :otp_ready_timeout
      String.contains?(value, "otp_stop_failed") -> :otp_stop_failed
      String.contains?(value, "query_failure") -> :query_failure
      String.contains?(value, "scoring_failure") -> :scoring_failure
      String.contains?(value, "pathways_runner_spawn_failed") -> :pathways_runner_spawn_failed
      String.contains?(value, "pathways_trip_test_failed") -> :pathways_trip_test_failed
      String.contains?(value, "pathways_persistence_failed") -> :pathways_persistence_failed
      String.contains?(value, "pathways_export_prep_failed") -> :pathways_export_prep_failed
      String.contains?(value, "pathways_task_crashed") -> :pathways_task_crashed
      String.contains?(value, "pathways_status_unavailable") -> :pathways_status_unavailable
      String.contains?(value, "pathways_run_not_found") -> :pathways_run_not_found
      String.contains?(value, "pathways_invalid_run_type") -> :pathways_invalid_run_type
      String.contains?(value, "pathways_results_unavailable") -> :pathways_results_unavailable
      true -> nil
    end
  end

  defp assign_pathways_error_panel(socket, error_payload) when is_map(error_payload) do
    pathways_failure = present_pathways_failure_for_payload(error_payload)

    socket
    |> assign(:pathways_prep_error, nil)
    |> assign(:pathways_failure, pathways_failure)
    |> assign(:validation_error, pathways_failure_message(error_payload))
  end

  defp assign_pathways_error_panel(socket, error_payload) do
    assign_pathways_error_panel(socket, %{
      reason: :pathways_trip_test_failed,
      details: %{error: inspect(error_payload)}
    })
  end

  defp pathways_failure_diagnostic(error_payload) do
    reason_text = payload_value(error_payload, :reason)

    if is_binary(reason_text) and String.contains?(reason_text, "build_command_failed") do
      exit_status =
        case Regex.run(~r/exit_status:\s*(\d+)/, reason_text, capture: :all_but_first) do
          [status] -> status
          _ -> nil
        end

      build_log_path =
        case Regex.run(~r|(\/[^\s,\"]+\/build\.log)|, reason_text, capture: :all_but_first) do
          [path] -> path
          _ -> nil
        end

      build_log_hint =
        case build_log_path do
          nil ->
            nil

          path ->
            case read_graph_build_log_hint(path) do
              nil -> "Graph build log: #{path}."
              hint -> "Graph build log: #{path}. #{hint}"
            end
        end

      case {exit_status, build_log_hint} do
        {nil, nil} -> "OTP graph build command failed."
        {status, nil} -> "OTP graph build command failed (exit status #{status})."
        {nil, hint} -> "OTP graph build command failed. #{hint}"
        {status, hint} -> "OTP graph build command failed (exit status #{status}). #{hint}"
      end
    else
      nil
    end
  end

  defp read_graph_build_log_hint(path) do
    case File.read(path) do
      {:ok, body} ->
        cond do
          String.contains?(body, "BoardingArea") and
              String.contains?(body, "NullPointerException") ->
            "OTP reported a BoardingArea NullPointerException while mapping GTFS stops. This often means a child stop is missing a valid parent_station assignment."

          String.contains?(body, "NullPointerException") ->
            "OTP reported a NullPointerException during graph build. This often means a child stop is missing a valid parent_station assignment."

          true ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp maybe_mark_pathways_run_failed(socket, reason) do
    case socket.assigns[:validation_run_id] do
      nil ->
        :ok

      validation_run_id ->
        validation_run_id
        |> Validations.get_validation_run()
        |> case do
          nil -> :ok
          run -> Validations.mark_pathways_failed(run, reason)
        end
    end
  end

  defp otp_data_requirements_summary, do: @otp_data_requirements_summary

  defp export_gtfs_zip(organization_id, gtfs_version_id, export_type) do
    case export_module().export_to_zip(organization_id, gtfs_version_id, export_type) do
      {:ok, zip_binary} ->
        warnings =
          case preflight_module().run(organization_id, gtfs_version_id) do
            :ok -> []
            {:error, issues} -> normalize_export_warnings(issues)
          end

        {:ok, zip_binary, warnings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_export_error(:no_data), do: "No data available to export."

  defp format_export_error(issues) when is_list(issues) do
    issues
    |> Enum.map(fn
      %{message: message} when is_binary(message) and message != "" -> message
      issue when is_map(issue) -> Map.get(issue, "message", inspect(issue))
      other -> inspect(other)
    end)
    |> Enum.join("; ")
  end

  defp format_export_error(reason) when is_binary(reason), do: reason
  defp format_export_error(_reason), do: "Export failed. Try again or contact support."

  defp normalize_export_warnings(warnings) when is_list(warnings) do
    Enum.map(warnings, fn
      %{message: _} = warning -> warning
      %{"message" => _} = warning -> normalize_string_keyed_warning(warning)
      other -> %{message: inspect(other), code: :unknown}
    end)
  end

  defp normalize_export_warnings(_), do: []

  defp normalize_string_keyed_warning(warning) do
    base = %{message: Map.get(warning, "message", "")}

    base
    |> maybe_put_warning_key(:code, Map.get(warning, "code"))
    |> maybe_put_warning_key(:details, string_keys_to_known_atoms(Map.get(warning, "details")))
    |> maybe_put_warning_key(:context, string_keys_to_known_atoms(Map.get(warning, "context")))
    |> maybe_put_warning_key(:stop_id, Map.get(warning, "stop_id"))
    |> maybe_put_warning_key(:pathway_id, Map.get(warning, "pathway_id"))
    |> maybe_put_warning_key(:trip_id, Map.get(warning, "trip_id"))
  end

  defp maybe_put_warning_key(map, _key, nil), do: map
  defp maybe_put_warning_key(map, key, value), do: Map.put(map, key, value)

  @known_warning_keys ~w(source_file source_field target_file target_field invalid_count file field identifier stop_id pathway_id trip_id value)a

  defp string_keys_to_known_atoms(nil), do: nil

  defp string_keys_to_known_atoms(map) when is_map(map) do
    known_strings = Map.new(@known_warning_keys, fn atom -> {Atom.to_string(atom), atom} end)

    Map.new(map, fn
      {k, v} when is_binary(k) ->
        case Map.fetch(known_strings, k) do
          {:ok, atom_key} -> {atom_key, v}
          :error -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  defp string_keys_to_known_atoms(other), do: other

  defp deduplicate_export_warnings(warnings) when is_list(warnings) do
    Enum.uniq_by(warnings, fn warning ->
      code = warning[:code] || :unknown
      identity = export_warning_identity(warning)
      {code, identity, warning[:message] || ""}
    end)
  end

  defp deduplicate_export_warnings(_), do: []

  defp export_warning_identity(warning) do
    cond do
      id = deep_warning_field(warning, :stop_id) -> id
      id = deep_warning_field(warning, :pathway_id) -> id
      id = deep_warning_field(warning, :trip_id) -> id
      true -> :unknown
    end
  end

  defp deep_warning_field(warning, field) do
    warning[field] ||
      (is_map(warning[:details]) && warning[:details][field]) ||
      (is_map(warning[:context]) && warning[:context][field]) ||
      nil
  end

  defp push_gtfs_download(socket, zip_binary) do
    version_name = socket.assigns.current_gtfs_version.name
    filename = "gtfs_#{version_name}_#{Date.utc_today()}.zip"

    push_event(socket, "download-file", %{
      data: Base.encode64(zip_binary),
      filename: filename
    })
  end

  defp format_export_warning_details(issue) do
    details = issue[:details]
    context = issue[:context]

    cond do
      is_map(details) and details[:source_file] ->
        source_field =
          if details[:source_field], do: ".#{details[:source_field]}", else: ""

        target_file =
          if details[:target_file], do: " -> #{details[:target_file]}", else: ""

        invalid_count =
          if details[:invalid_count], do: " (#{details[:invalid_count]} invalid)", else: ""

        "#{details[:source_file]}#{source_field}#{target_file}#{invalid_count}"

      is_map(context) ->
        [:file, :field, :identifier, :stop_id, :pathway_id, :trip_id, :value]
        |> Enum.map(fn key ->
          case context[key] do
            nil -> nil
            "" -> nil
            v -> "#{key}: #{v}"
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          parts -> Enum.join(parts, " | ")
        end

      true ->
        nil
    end
  end

  defp export_module do
    Application.get_env(:gtfs_planner, :gtfs_export_module, GtfsPlanner.Gtfs.Export)
  end

  defp preflight_module do
    Application.get_env(:gtfs_planner, :otp_preflight_module, GtfsPlanner.Otp.Preflight)
  end
end
