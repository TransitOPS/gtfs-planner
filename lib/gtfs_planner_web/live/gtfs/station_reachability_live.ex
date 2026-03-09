defmodule GtfsPlannerWeb.Gtfs.StationReachabilityLive do
  @moduledoc """
  LiveView for station-level reachability validation.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Validations
  alias GtfsPlannerWeb.Gtfs.ExportLive

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

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Reachability")
     |> assign(:user_roles, user_roles)
     |> assign(:station, nil)
     |> assign(:stop_id, nil)
     |> assign(:validation_run_id, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:pathways_failure, nil)
     |> assign(:pathways_failure_diagnostics, [])
     |> assign(:pathways_case_results, [])
     |> assign(:pathways_prep_detailed_progress, false)
     |> assign(:recent_validation_runs, [])}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id}, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}

      station ->
        recent_validation_runs =
          Validations.list_recent_station_reachability_runs(
            organization_id,
            gtfs_version_id,
            stop_id,
            5
          )

        {:noreply,
         socket
         |> assign(:stop_id, stop_id)
         |> assign(:station, station)
         |> assign(:recent_validation_runs, recent_validation_runs)}
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
      <:sub_header>
        <.station_sub_nav
          :if={@station}
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:reachability}
        />
      </:sub_header>

      <section id="station-reachability" class="space-y-4">
        <header class="flex flex-col gap-3 border-b border-base-200 pb-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h2 class="text-lg font-semibold text-base-content">Reachability</h2>
            <p class="text-sm text-base-content/70">
              Run station-scoped pathways validation for this station.
            </p>
          </div>

          <.button
            id="run-station-reachability"
            type="button"
            phx-click="run_reachability"
            disabled={@validating || is_nil(@stop_id)}
          >
            <%= if @validating do %>
              Running…
            <% else %>
              Run reachability
            <% end %>
          </.button>
        </header>

        <%= if @validating do %>
          <div id="station-reachability-progress" class="space-y-3">
            <progress
              class="progress progress-primary w-full"
              value={Map.get(@validation_progress || %{}, :percent, 10)}
              max="100"
            />
            <div class="flex items-center gap-2 text-sm text-base-content/80">
              <span class="loading loading-spinner loading-sm"></span>
              <span>{phase_label(Map.get(@validation_progress || %{}, :phase))}</span>
            </div>
          </div>
        <% end %>

        <%= if @validation_error do %>
          <section
            id="station-reachability-error-panel"
            role="alert"
            class="rounded-xl border border-error/40 bg-base-100"
          >
            <div class="flex items-start gap-3 border-b border-error/20 px-4 py-3">
              <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 shrink-0 text-error" />
              <div class="min-w-0 flex-1">
                <%= if @pathways_failure do %>
                  <h3 class="text-base font-semibold leading-6 text-base-content">
                    {@pathways_failure.title}
                  </h3>
                  <p class="mt-1 text-sm leading-5 text-base-content/80">
                    {@pathways_failure.summary}
                  </p>
                <% end %>
                <p class="mt-2 text-sm leading-5 text-base-content/80">{@validation_error}</p>
              </div>
            </div>

            <div class="space-y-4 px-4 py-4 text-sm">
              <%= if @pathways_failure && @pathways_failure.blocking_issues != [] do %>
                <section id="station-pathways-failure-blocking-issues" class="space-y-2">
                  <h4 class="text-xs font-semibold uppercase tracking-wide text-error">
                    Blocking issues
                  </h4>
                  <ul class="space-y-2">
                    <li
                      :for={issue <- @pathways_failure.blocking_issues}
                      class="border-l-2 border-error/60 pl-3"
                    >
                      <p class="leading-5 text-base-content">{issue.message}</p>
                      <p :if={issue.context_summary} class="mt-1 font-mono text-xs text-base-content/70">
                        {issue.context_summary}
                      </p>
                    </li>
                  </ul>
                </section>
              <% end %>

              <%= if @pathways_failure do %>
                <section id="station-pathways-failure-checks" class="space-y-2 border-t border-base-300 pt-3">
                  <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                    Recommended checks
                  </h4>
                  <ul class="list-disc space-y-1 pl-5 text-base-content/85">
                    <li :for={check <- @pathways_failure.checks}>{check}</li>
                  </ul>
                </section>
              <% end %>

              <%= if @pathways_failure_diagnostics != [] do %>
                <section id="station-pathways-failure-diagnostics" class="space-y-2 border-t border-base-300 pt-3">
                  <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                    Technical diagnostics
                  </h4>
                  <dl class="divide-y divide-base-300 text-sm text-base-content/85">
                    <div
                      :for={detail <- @pathways_failure_diagnostics}
                      class="grid grid-cols-1 gap-1 py-2 sm:grid-cols-[12rem,1fr] sm:gap-3"
                    >
                      <dt class="font-medium text-base-content/80">{detail.label}:</dt>
                      <dd class="break-all font-mono text-xs sm:text-sm">{detail.value}</dd>
                    </div>
                  </dl>
                </section>
              <% end %>

              <%= if @pathways_failure do %>
                <section
                  id="station-otp-data-requirements-summary"
                  class="rounded-lg border border-base-300 bg-base-100 p-4"
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
            </div>
          </section>
        <% end %>

        <%= if @validation_result do %>
          <section id="station-reachability-summary" class="space-y-3 border-t border-base-200 pt-4">
            <h3 class="text-sm font-semibold text-base-content">Validation summary</h3>

            <dl class="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
              <div class="rounded border border-base-200 px-3 py-2" id="reachability-summary-total">
                <dt class="text-xs uppercase tracking-wide text-base-content/70">Total</dt>
                <dd class="text-base font-semibold text-base-content">
                  {@validation_result.summary_cards.total}
                </dd>
              </div>
              <div class="rounded border border-base-200 px-3 py-2" id="reachability-summary-passed">
                <dt class="text-xs uppercase tracking-wide text-base-content/70">Passed</dt>
                <dd class="text-base font-semibold text-base-content">
                  {@validation_result.summary_cards.passed}
                </dd>
              </div>
              <div class="rounded border border-base-200 px-3 py-2" id="reachability-summary-failed">
                <dt class="text-xs uppercase tracking-wide text-base-content/70">Failed</dt>
                <dd class="text-base font-semibold text-base-content">
                  {@validation_result.summary_cards.failed}
                </dd>
              </div>
              <div class="rounded border border-base-200 px-3 py-2" id="reachability-summary-pass-rate">
                <dt class="text-xs uppercase tracking-wide text-base-content/70">Pass rate</dt>
                <dd class="text-base font-semibold text-base-content">
                  {@validation_result.summary_cards.pass_rate}%
                </dd>
              </div>
            </dl>

            <div :if={@validation_result.top_failure_rows != []} id="station-reachability-top-failures">
              <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                Top failure categories
              </h4>
              <ul class="mt-2 space-y-1 text-sm">
                <li
                  :for={row <- @validation_result.top_failure_rows}
                  class="flex items-center justify-between rounded border border-base-200 px-3 py-2"
                >
                  <span>{row.category}</span>
                  <span class="font-medium">{row.count}</span>
                </li>
              </ul>
            </div>

            <section id="station-trip-overview" class="grid grid-cols-2 gap-2 sm:grid-cols-4">
              <div class="rounded border border-base-200 px-3 py-2">
                <div class="text-xs uppercase tracking-wide text-base-content/70">Total tests</div>
                <div class="text-base font-semibold text-base-content">
                  {@validation_result.trip_overview.total_tests}
                </div>
              </div>
              <div class="rounded border border-base-200 px-3 py-2">
                <div class="text-xs uppercase tracking-wide text-base-content/70">Passed</div>
                <div class="text-base font-semibold text-success">
                  {@validation_result.trip_overview.pass_count}
                </div>
              </div>
              <div class="rounded border border-base-200 px-3 py-2">
                <div class="text-xs uppercase tracking-wide text-base-content/70">Warnings</div>
                <div class="text-base font-semibold text-warning">
                  {@validation_result.trip_overview.warning_count}
                </div>
              </div>
              <div class="rounded border border-base-200 px-3 py-2">
                <div class="text-xs uppercase tracking-wide text-base-content/70">Failed</div>
                <div class="text-base font-semibold text-error">
                  {@validation_result.trip_overview.fail_count}
                </div>
              </div>
            </section>

            <div class="overflow-x-auto" id="station-pathways-case-results">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Test Case</th>
                    <th>Status</th>
                    <th>Issue</th>
                    <th>Duration (s)</th>
                    <th>Distance (m)</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- @pathways_case_results}
                    id={"station-pathways-case-row-#{row.order_index}"}
                  >
                    <td class="font-mono text-xs">{row.walkability_test_id}</td>
                    <td>
                      <span class={["badge badge-sm", case_status_badge_class(pathways_case_display_status(row))]}>
                        {String.upcase(to_string(pathways_case_display_status(row)))}
                      </span>
                    </td>
                    <td>{List.first(pathways_case_issues(row))}</td>
                    <td>{row.duration_seconds || "-"}</td>
                    <td>{format_pathways_distance(row.distance_meters)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <%= if @recent_validation_runs != [] do %>
          <section id="recent-station-runs" class="space-y-3 border-t border-base-200 pt-4">
            <h3 class="text-sm font-semibold text-base-content">Recent reachability runs</h3>

            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Run</th>
                    <th>Date</th>
                    <th>Status</th>
                    <th class="text-right">Errors</th>
                    <th class="text-right">Warnings</th>
                    <th class="text-right">Infos</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @recent_validation_runs} id={"recent-station-run-#{run.id}"}>
                    <td>
                      <.link
                        navigate={
                          ~p"/gtfs/#{@current_gtfs_version.id}/station-reachability/#{run.id}?stop_id=#{@station.stop_id}"
                        }
                        class="link link-primary"
                      >
                        {run.id}
                      </.link>
                    </td>
                    <td class="text-sm text-base-content/70">{format_date(run.started_at)}</td>
                    <td>
                      <span class="badge badge-outline badge-sm">{run.status}</span>
                    </td>
                    <td class="text-right">{run.errors_count || 0}</td>
                    <td class="text-right">{run.warnings_count || 0}</td>
                    <td class="text-right">{run.infos_count || 0}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("run_reachability", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.stop_id

    case apply(Validations, :start_station_reachability_test, [
           organization_id,
           gtfs_version_id,
           station_stop_id,
           [status_callback: pathways_prep_status_callback(self())]
         ]) do
      {:ok, run} ->
        Process.send_after(
          self(),
          {:poll_pathways_trip_test_status, run.id},
          @pathways_trip_test_poll_interval_ms
        )

        {:noreply,
         socket
         |> assign(:validation_run_id, run.id)
         |> assign(:validating, true)
         |> assign(:pathways_prep_detailed_progress, false)
         |> assign(:validation_progress, pathways_status_progress(run.status))
         |> assign(:validation_error, nil)
         |> assign(:validation_result, nil)
         |> assign(:pathways_failure_diagnostics, [])
         |> assign(:pathways_case_results, [])
         |> assign(:pathways_failure, nil)}

      {:error, reason} ->
        {:noreply, assign_pathways_error_panel(socket, reason)}
    end
  end

  @impl true
  def handle_info({:pathways_prep_progress, payload}, socket) do
    phase = pathways_prep_phase(payload)

    {:noreply,
     socket
     |> assign(:pathways_prep_detailed_progress, true)
     |> assign(:validation_progress, %{phase: {:pathways_prep, phase}, percent: phase_percent(phase)})}
  end

  @impl true
  def handle_info({:poll_pathways_trip_test_status, validation_run_id}, socket) do
    if socket.assigns.validation_run_id == validation_run_id and socket.assigns.validating do
      case Validations.get_pathways_trip_test_status(validation_run_id) do
        {:ok, %{status: status} = status_payload} when status in ["started", "running"] ->
          Process.send_after(
            self(),
            {:poll_pathways_trip_test_status, validation_run_id},
            @pathways_trip_test_poll_interval_ms
          )

          {:noreply,
           socket
           |> assign(:validation_progress, to_validation_progress(status_payload))}

        {:ok, %{status: "completed"} = status_payload} ->
          case Validations.get_pathways_trip_test_results(validation_run_id) do
            {:ok, pathways_results} ->
              {:noreply,
               socket
               |> assign(:validating, false)
               |> assign(:pathways_prep_detailed_progress, false)
               |> assign(:validation_progress, to_validation_progress(status_payload))
               |> assign(:validation_result, map_completed_validation_result(pathways_results))
               |> assign(:validation_error, nil)
              |> assign(:pathways_failure_diagnostics, [])
              |> assign(:pathways_case_results, Map.get(pathways_results, :walkability_test_run_results, []))
               |> refresh_recent_validation_runs()}

            {:error, reason} ->
              {:noreply,
               socket
               |> assign(:validating, false)
               |> assign(:pathways_prep_detailed_progress, false)
               |> assign(:validation_progress, to_validation_progress(status_payload))
               |> assign(:validation_result, nil)
               |> assign(:pathways_case_results, [])
               |> assign_pathways_error_panel(reason)
               |> refresh_recent_validation_runs()}
          end

        {:ok, %{status: "failed"} = status_payload} ->
          error_payload = Map.get(status_payload, :error_payload) || status_payload

          {:noreply,
           socket
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, to_validation_progress(status_payload))
           |> assign(:pathways_case_results, [])
           |> assign_pathways_error_panel(error_payload)
           |> refresh_recent_validation_runs()}

        {:ok, status_payload} ->
          {:noreply,
           socket
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign(:validation_progress, to_validation_progress(status_payload))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:validating, false)
           |> assign(:pathways_prep_detailed_progress, false)
           |> assign_pathways_error_panel(reason)}
      end
    else
      {:noreply, socket}
    end
  end

  defp to_validation_progress(status_payload) do
    phase = status_phase(status_payload.status)

    %{
      phase: {:pathways_prep, phase},
      percent: phase_percent(phase),
      status: status_payload.status,
      started_at: status_payload.started_at,
      completed_at: status_payload.completed_at,
      duration_ms: status_payload.duration_ms,
      errors_count: status_payload.errors_count,
      warnings_count: status_payload.warnings_count,
      infos_count: status_payload.infos_count
    }
  end

  defp top_failure_rows(pathways_results) do
    pathways_results
    |> Map.get(:walkability_test_run_results, [])
    |> Enum.reduce(%{}, fn case_result, counts ->
      case case_result.failure_category do
        nil ->
          counts

        failure_category ->
          Map.update(counts, failure_category, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort_by(fn {failure_category, count} -> {-count, failure_category} end)
    |> Enum.map(fn {failure_category, count} ->
      %{
        category: failure_category,
        count: count
      }
    end)
  end

  defp assign_pathways_error_panel(socket, error_payload) when is_map(error_payload) do
    pathways_failure =
      error_payload
      |> ExportLive.classify_pathways_failure_category()
      |> ExportLive.present_pathways_failure(error_payload)

    message =
      case pathways_failure.summary do
        summary when is_binary(summary) and summary != "" -> summary
        _summary -> "Pathways validation failed"
      end

    socket
    |> assign(:pathways_failure, pathways_failure)
    |> assign(:validation_result, nil)
    |> assign(:validation_error, pathways_failure_message(error_payload, message))
    |> assign(:pathways_failure_diagnostics, pathways_failure_diagnostics(error_payload))
  end

  defp assign_pathways_error_panel(socket, error_payload) do
    assign_pathways_error_panel(socket, %{
      reason: :pathways_trip_test_failed,
      details: %{error: inspect(error_payload)}
    })
  end

  defp pathways_trip_overview(pathways_case_results) when is_list(pathways_case_results) do
    Enum.reduce(pathways_case_results, %{total_tests: 0, pass_count: 0, warning_count: 0, fail_count: 0}, fn row,
                                                                                                             acc ->
      status = pathways_case_display_status(row)

      acc
      |> Map.update!(:total_tests, &(&1 + 1))
      |> increment_pathways_trip_status(status)
    end)
  end

  defp pathways_trip_overview(_pathways_case_results),
    do: %{total_tests: 0, pass_count: 0, warning_count: 0, fail_count: 0}

  defp increment_pathways_trip_status(acc, "pass"), do: Map.update!(acc, :pass_count, &(&1 + 1))
  defp increment_pathways_trip_status(acc, "warning"), do: Map.update!(acc, :warning_count, &(&1 + 1))
  defp increment_pathways_trip_status(acc, "failed"), do: Map.update!(acc, :fail_count, &(&1 + 1))
  defp increment_pathways_trip_status(acc, _status), do: acc

  defp pathways_case_display_status(row) do
    cond do
      row.failure_category == "query_failure" -> "failed"
      row.failure_category == "scoring_failure" -> "warning"
      true -> "pass"
    end
  end

  defp pathways_case_issues(row) do
    case row.failure_category do
      "query_failure" -> ["Query failure"]
      "scoring_failure" -> ["Criteria checks failed"]
      _other -> ["All criteria passed"]
    end
  end

  defp case_status_badge_class("pass"), do: "badge-success"
  defp case_status_badge_class("warning"), do: "badge-warning"
  defp case_status_badge_class("failed"), do: "badge-error"
  defp case_status_badge_class(_status), do: "badge-ghost"

  defp format_pathways_distance(nil), do: "-"

  defp format_pathways_distance(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_distance(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pathways_distance(_value), do: "-"

  defp pathways_failure_message(error_payload, default_message) do
    reason = Map.get(error_payload, :reason) || Map.get(error_payload, "reason")
    normalized_code = normalize_pathways_failure_code(reason)

    case normalized_code do
      nil -> default_message
      code -> Map.get(@pathways_failure_messages, code, default_message)
    end
  end

  defp normalize_pathways_failure_code(value) when is_atom(value), do: value

  defp normalize_pathways_failure_code(value) when is_binary(value) do
    case value do
      "otp_runtime_failed" -> :otp_runtime_failed
      "otp_runtime_already_running" -> :otp_runtime_already_running
      "otp_start_failed" -> :otp_start_failed
      "otp_ready_timeout" -> :otp_ready_timeout
      "otp_stop_failed" -> :otp_stop_failed
      "pathways_runner_spawn_failed" -> :pathways_runner_spawn_failed
      "pathways_trip_test_failed" -> :pathways_trip_test_failed
      "pathways_persistence_failed" -> :pathways_persistence_failed
      "pathways_export_prep_failed" -> :pathways_export_prep_failed
      "pathways_task_crashed" -> :pathways_task_crashed
      "pathways_status_unavailable" -> :pathways_status_unavailable
      "pathways_run_not_found" -> :pathways_run_not_found
      "pathways_invalid_run_type" -> :pathways_invalid_run_type
      "pathways_results_unavailable" -> :pathways_results_unavailable
      "query_failure" -> :query_failure
      "scoring_failure" -> :scoring_failure
      "no_walkability_tests" -> :no_walkability_tests
      _other -> nil
    end
  end

  defp normalize_pathways_failure_code(_value), do: nil

  defp pathways_failure_diagnostics(error_payload) when is_map(error_payload) do
    details = Map.get(error_payload, :details) || Map.get(error_payload, "details") || %{}

    [
      presenter_detail("Reason", Map.get(error_payload, :reason) || Map.get(error_payload, "reason")),
      presenter_detail("Stage", Map.get(details, :stage) || Map.get(details, "stage")),
      presenter_detail("Error", Map.get(details, :error) || Map.get(details, "error"))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp pathways_failure_diagnostics(_error_payload), do: []

  defp presenter_detail(_label, nil), do: nil
  defp presenter_detail(_label, ""), do: nil

  defp presenter_detail(label, value) do
    %{label: label, value: presenter_detail_value(value)}
  end

  defp presenter_detail_value(value) when is_binary(value), do: value
  defp presenter_detail_value(value) when is_atom(value), do: Atom.to_string(value)
  defp presenter_detail_value(value) when is_integer(value), do: Integer.to_string(value)
  defp presenter_detail_value(value), do: inspect(value)

  defp otp_data_requirements_summary, do: @otp_data_requirements_summary

  defp refresh_recent_validation_runs(socket) do
    stop_id = socket.assigns[:stop_id]

    if is_binary(stop_id) and stop_id != "" do
      recent_validation_runs =
        Validations.list_recent_station_reachability_runs(
          socket.assigns.current_organization.id,
          socket.assigns.current_gtfs_version.id,
          stop_id,
          5
        )

      assign(socket, :recent_validation_runs, recent_validation_runs)
    else
      socket
    end
  end

  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")

  defp pathways_prep_status_callback(live_view_pid) do
    fn payload ->
      send(live_view_pid, {:pathways_prep_progress, payload})
    end
  end

  defp pathways_status_progress("started"), do: %{phase: {:pathways_prep, :cache_check}, percent: 10}
  defp pathways_status_progress("running"), do: %{phase: {:pathways_prep, :running}, percent: 50}
  defp pathways_status_progress(_status), do: %{phase: :processing, percent: 95}

  defp status_phase("started"), do: :cache_check
  defp status_phase("running"), do: :running
  defp status_phase("completed"), do: :done
  defp status_phase("failed"), do: :failed
  defp status_phase(_status), do: :running

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

  defp map_completed_validation_result(pathways_results) do
    result_json = pathways_results.result_json || %{}
    summary = Map.get(result_json, "summary", %{})
    case_results = Map.get(pathways_results, :walkability_test_run_results, [])

    %{
      summary_cards: %{
        total: Map.get(summary, "total", 0),
        passed: Map.get(summary, "passed", 0),
        failed: Map.get(summary, "failed", 0),
        pass_rate: Map.get(summary, "pass_rate", 0.0)
      },
      top_failure_rows: top_failure_rows(pathways_results),
      trip_overview: pathways_trip_overview(case_results)
    }
  end
end
