defmodule GtfsPlannerWeb.Gtfs.ValidationResultLive do
  use GtfsPlannerWeb, :live_view
  alias GtfsPlannerWeb.Gtfs.ExportLive
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts
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

  @pathways_criteria_overview_definitions [
    %{kind: "expected_traversable", label: "Traversable"},
    %{kind: "duration_seconds_range", label: "Duration range"},
    %{kind: "distance_meters_range", label: "Distance range"},
    %{kind: "expected_wheelchair_accessible", label: "Wheelchair accessible"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Validation Results")
     |> assign(:user_roles, user_roles)
     |> assign(:expanded_codes, MapSet.new())
     |> assign(:pathways_preflight_issues, nil)
     |> assign(:pathways_failure, nil)
     |> assign(:pathways_failure_message, nil)
     |> assign(:pathways_failure_diagnostics, [])
     |> assign(:pathways_case_results, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"validation_id" => validation_id}, _uri, socket) do
    run = Validations.get_validation_run!(validation_id)
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    # Verify authorization: ensure the run belongs to the current organization
    if run.organization_id != organization_id do
      {:noreply,
       socket
       |> put_flash(:error, "Unauthorized access to validation run")
       |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/export")}
    else
      validation_runs_history =
        Validations.list_validation_runs(organization_id, gtfs_version_id)

      {run, pathways_case_results} = load_pathways_render_data(run)
      pathways_failure = pathways_failure(run)
      pathways_failure_message = pathways_failure_message(run)
      pathways_failure_diagnostics = pathways_failure_diagnostics(run)
      pathways_preflight_issues = pathways_preflight_issues(run)

      {:noreply,
       socket
       |> assign(:validation_id, validation_id)
       |> assign(:run, run)
       |> assign(:pathways_preflight_issues, pathways_preflight_issues)
       |> assign(:pathways_failure, pathways_failure)
       |> assign(:pathways_failure_message, pathways_failure_message)
       |> assign(:pathways_failure_diagnostics, pathways_failure_diagnostics)
       |> assign(:pathways_case_results, pathways_case_results)
       |> stream(:validation_runs, validation_runs_history)
       |> maybe_schedule_pathways_status_poll(run)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:poll_pathways_trip_test_status, validation_run_id}, socket) do
    if poll_current_pathways_run?(socket, validation_run_id) do
      case Validations.get_pathways_trip_test_status(validation_run_id) do
        {:ok, %{status: "started"}} ->
          schedule_pathways_status_poll(validation_run_id)
          {:noreply, refresh_pathways_run(socket, validation_run_id)}

        {:ok, %{status: "running"}} ->
          schedule_pathways_status_poll(validation_run_id)
          {:noreply, refresh_pathways_run(socket, validation_run_id)}

        {:ok, %{status: "completed"}} ->
          {:noreply, refresh_pathways_run(socket, validation_run_id)}

        {:ok, %{status: "failed"}} ->
          {:noreply, refresh_pathways_run(socket, validation_run_id)}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         valid_version_for_org?(version_id, current_organization.id) do
      validation_id = socket.assigns[:validation_id]

      if validation_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/validation/#{validation_id}")}
      else
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_notice", %{"code" => code}, socket) do
    expanded_codes = socket.assigns.expanded_codes

    updated_codes =
      if MapSet.member?(expanded_codes, code) do
        MapSet.delete(expanded_codes, code)
      else
        MapSet.put(expanded_codes, code)
      end

    {:noreply, assign(socket, :expanded_codes, updated_codes)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="drawer drawer-end">
      <input id="validation-history-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content">
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
            Validation Results
            <:subtitle>
              {validation_subtitle(@run)}
            </:subtitle>
            <:actions>
              <label for="validation-history-drawer" class="btn btn-outline btn-sm">
                View History
              </label>
              <.link
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/export"}
                class="btn btn-outline btn-sm"
              >
                Back to Export
              </.link>
            </:actions>
          </.header>

          <%!-- Status Badge --%>
          <div class="mt-6">
            <.status_badge status={@run.status} label={String.upcase(@run.status)} class="text-base" />
          </div>

          <%= cond do %>
            <% @run.status == "failed" -> %>
              <%!-- Failed State --%>
              <section class="mt-6 rounded-xl border border-error/40 bg-base-100" role="alert">
                <div class="flex items-start gap-3 border-b border-error/20 px-4 py-3">
                  <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 shrink-0 text-error" />
                  <div class="min-w-0 flex-1">
                    <%= if @pathways_failure do %>
                      <h3 class="text-base font-semibold leading-6" id="pathways-failure-title">
                        {@pathways_failure.title}
                      </h3>
                      <p
                        class="mt-1 text-sm leading-5 text-base-content/85"
                        id="pathways-failure-summary"
                      >
                        {@pathways_failure.summary}
                      </p>
                      <p
                        class="mt-2 text-sm leading-5 text-base-content/80"
                        id="pathways-failure-status-message"
                      >
                        {@pathways_failure_message}
                      </p>
                    <% else %>
                      <h3 class="text-base font-semibold leading-6">Validation Failed</h3>
                      <p class="mt-1 text-sm leading-5 text-base-content/85">
                        {failure_summary(@run, @pathways_preflight_issues)}
                      </p>
                    <% end %>
                  </div>
                </div>

                <div class="space-y-4 px-4 py-4">
                  <%= if @pathways_failure && @pathways_failure.blocking_issues != [] do %>
                    <section id="pathways-failure-blocking-issues" class="space-y-2">
                      <h4 class="text-xs font-semibold uppercase tracking-wide text-error">
                        Blocking issues
                      </h4>
                      <ul class="space-y-2 text-sm">
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

                  <%= if @pathways_failure do %>
                    <section
                      id="pathways-failure-checks"
                      class="space-y-2 border-t border-base-300 pt-3"
                    >
                      <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                        Recommended checks
                      </h4>
                      <ul class="list-disc space-y-1 pl-5 text-base-content/85 text-sm">
                        <li :for={check <- @pathways_failure.checks}>{check}</li>
                      </ul>
                    </section>
                  <% end %>

                  <%= if @pathways_preflight_issues do %>
                    <section id="pathways-preflight-issues" class="space-y-4">
                      <%= if @pathways_preflight_issues.blocking_errors != [] do %>
                        <section id="pathways-preflight-blocking-errors" class="space-y-2">
                          <h4 class="text-xs font-semibold uppercase tracking-wide text-error">
                            Blocking errors
                          </h4>
                          <ul class="space-y-2 text-sm">
                            <li
                              :for={issue <- @pathways_preflight_issues.blocking_errors}
                              class="border-l-2 border-error/60 pl-3"
                            >
                              <p class="leading-5 text-base-content">{issue.message}</p>
                              <p
                                :if={issue_context_text = preflight_issue_context(issue)}
                                class="mt-1 font-mono text-xs leading-5 text-base-content/70"
                              >
                                {issue_context_text}
                              </p>
                            </li>
                          </ul>
                        </section>
                      <% end %>

                      <%= if @pathways_preflight_issues.warnings != [] do %>
                        <section
                          id="pathways-preflight-warnings"
                          class="space-y-2 border-t border-base-300 pt-3"
                        >
                          <h4 class="text-xs font-semibold uppercase tracking-wide text-warning">
                            Warnings
                          </h4>
                          <ul class="space-y-2 text-sm">
                            <li
                              :for={issue <- @pathways_preflight_issues.warnings}
                              class="border-l-2 border-warning/60 pl-3"
                            >
                              <p class="leading-5 text-base-content">{issue.message}</p>
                              <p
                                :if={issue_context_text = preflight_issue_context(issue)}
                                class="mt-1 font-mono text-xs leading-5 text-base-content/70"
                              >
                                {issue_context_text}
                              </p>
                            </li>
                          </ul>
                        </section>
                      <% end %>
                    </section>
                  <% end %>

                  <%= if @pathways_failure_diagnostics != [] do %>
                    <section
                      id="pathways-failure-diagnostics"
                      class="space-y-2 border-t border-base-300 pt-3"
                    >
                      <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                        Technical diagnostics
                      </h4>
                      <dl class="divide-y divide-base-300 text-sm text-base-content/85">
                        <div
                          :for={detail <- @pathways_failure_diagnostics}
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

                  <%= if @pathways_failure do %>
                    <section
                      id="otp-data-requirements-summary"
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
            <% @run.status in ["started", "running"] -> %>
              <%!-- Loading State --%>
              <div class="flex items-center justify-center min-h-[400px] mt-6">
                <div class="text-center">
                  <div class="loading loading-spinner loading-lg"></div>
                  <p class="mt-4 text-base-content/60">
                    <%= if @run.status == "started" do %>
                      Validation starting...
                    <% else %>
                      Validation in progress...
                    <% end %>
                  </p>
                </div>
              </div>
            <% @run.status == "completed" and not is_nil(@run.result_json) and @run.run_type == "pathways_tests" -> %>
              <% pathways_trip_overview = pathways_trip_overview(@pathways_case_results) %>
              <% pathways_case_criteria_checks =
                pathways_case_criteria_checks(@pathways_case_results) %>
              <% pathways_criteria_overview_rows = pathways_criteria_overview(@pathways_case_results) %>

              <.pathways_trip_visualization_overview_section trip_overview={pathways_trip_overview} />

              <.pathways_criteria_comparison_section criteria_overview_rows={
                pathways_criteria_overview_rows
              } />

              <section
                id="pathways-case-results"
                class="mt-8 rounded-xl border border-base-content/20 bg-base-100"
              >
                <div class="px-4 py-3 border-b border-base-content/15">
                  <h3 class="text-sm font-semibold">Per-Test Results</h3>
                </div>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Test Case</th>
                        <th>Status</th>
                        <th>Issue</th>
                        <th>Duration (s)</th>
                        <th>Distance (m)</th>
                        <th>Origin</th>
                        <th>Destination</th>
                        <th>Start Time</th>
                        <th>End Time</th>
                      </tr>
                    </thead>
                    <%= for row <- @pathways_case_results do %>
                      <% itinerary_step_rows =
                        pathways_itinerary_step_rows(row.itinerary_steps_json) %>

                      <tbody
                        id={"pathways-case-group-#{row.order_index}"}
                        class="border-t-2 border-base-content/15"
                      >
                        <tr id={"pathways-case-row-#{row.order_index}"} class="bg-base-100">
                          <td class="font-mono text-xs">{row.walkability_test_id}</td>
                          <td>
                            <.status_badge
                              status={pathways_case_display_status(row)}
                              label={String.upcase(to_string(pathways_case_display_status(row)))}
                            />
                          </td>
                          <td>
                            <ol class="list-decimal list-inside text-xs leading-5 space-y-0.5 marker:text-base-content/60">
                              <li :for={issue <- pathways_case_issues(row)}>{issue}</li>
                            </ol>
                          </td>
                          <td>{row.duration_seconds || "-"}</td>
                          <td>{format_pathways_distance(row.distance_meters)}</td>
                          <td>{pathways_case_origin(row)}</td>
                          <td>{pathways_case_destination(row)}</td>
                          <td>{format_pathways_time(row.itinerary_start_time)}</td>
                          <td>{format_pathways_time(row.itinerary_end_time)}</td>
                        </tr>

                        <tr id={"pathways-case-criteria-row-#{row.order_index}"} class="bg-base-100">
                          <td colspan="9" class="p-0 border-t border-base-content/10">
                            <details
                              id={"pathways-case-criteria-details-#{row.order_index}"}
                              class="border-t border-base-300"
                            >
                              <summary class="cursor-pointer px-3 py-2 text-xs font-semibold text-base-content/80">
                                Criteria checks
                              </summary>

                              <div class="px-3 pb-3">
                                <% criteria_checks =
                                  Map.get(pathways_case_criteria_checks, row.order_index, []) %>

                                <div class="mb-3" id={"pathways-case-criteria-#{row.order_index}"}>
                                  <%= if criteria_checks == [] do %>
                                    <p
                                      id={"pathways-case-criteria-empty-#{row.order_index}"}
                                      class="text-xs text-base-content/70"
                                    >
                                      No expected criteria configured.
                                    </p>
                                  <% else %>
                                    <div class="overflow-x-auto">
                                      <table
                                        id={"pathways-case-criteria-table-#{row.order_index}"}
                                        class="table table-xs"
                                      >
                                        <thead>
                                          <tr>
                                            <th>Criterion</th>
                                            <th>Expected</th>
                                            <th>Actual</th>
                                            <th>Status</th>
                                          </tr>
                                        </thead>
                                        <tbody>
                                          <tr
                                            :for={check <- criteria_checks}
                                            id={
                                              "pathways-case-criteria-check-#{row.order_index}-#{check.kind}"
                                            }
                                          >
                                            <td>{check.label}</td>
                                            <td class="font-mono">
                                              {format_pathways_criteria_value(check.expected)}
                                            </td>
                                            <td class="font-mono">
                                              {format_pathways_criteria_value(check.actual)}
                                            </td>
                                            <td>
                                              <span class={[
                                                "inline-flex items-center gap-1 font-semibold",
                                                pathways_criteria_status_class(check.status)
                                              ]}>
                                                <.icon
                                                  name={pathways_criteria_status_icon(check.status)}
                                                  class="w-4 h-4"
                                                />
                                                {pathways_criteria_status_label(check.status)}
                                              </span>
                                            </td>
                                          </tr>
                                        </tbody>
                                      </table>
                                    </div>
                                  <% end %>
                                </div>
                              </div>
                            </details>
                          </td>
                        </tr>

                        <tr id={"pathways-case-itinerary-row-#{row.order_index}"} class="bg-base-100">
                          <td colspan="9" class="p-0 border-t border-base-content/10">
                            <details
                              id={"pathways-case-itinerary-details-#{row.order_index}"}
                              class="border-t border-base-300"
                            >
                              <summary class="cursor-pointer px-3 py-2 text-xs font-semibold text-base-content/80">
                                Step-by-step itinerary
                              </summary>

                              <div class="px-3 pb-3">
                                <%= if pathways_empty_itinerary?(itinerary_step_rows) do %>
                                  <p
                                    id={"pathways-case-itinerary-empty-#{row.order_index}"}
                                    class="text-xs text-base-content/70"
                                  >
                                    {pathways_empty_itinerary_text()}
                                  </p>
                                <% else %>
                                  <div class="overflow-x-auto">
                                    <table
                                      id={"pathways-case-itinerary-table-#{row.order_index}"}
                                      class="table table-xs"
                                    >
                                      <thead>
                                        <tr>
                                          <th>Step</th>
                                          <th>Leg Mode</th>
                                          <th>Street</th>
                                          <th>Relative</th>
                                          <th>Absolute</th>
                                          <th>Distance (m)</th>
                                        </tr>
                                      </thead>
                                      <tbody>
                                        <tr
                                          :for={step <- itinerary_step_rows}
                                          id={
                                            "pathways-case-itinerary-step-#{row.order_index}-#{step.leg_index}-#{step.step_index}"
                                          }
                                        >
                                          <td>{step.step_index}</td>
                                          <td>{step.mode}</td>
                                          <td>{step.street_name}</td>
                                          <td>{step.relative_direction}</td>
                                          <td>{step.absolute_direction}</td>
                                          <td>{format_pathways_distance(step.distance_meters)}</td>
                                        </tr>
                                      </tbody>
                                    </table>
                                  </div>
                                <% end %>
                              </div>
                            </details>
                          </td>
                        </tr>
                      </tbody>
                    <% end %>
                  </table>
                </div>
              </section>
            <% @run.status == "completed" and not is_nil(@run.result_json) -> %>
              <%!-- Completed State with Results --%>
              <%!-- Summary Stats --%>
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mt-6">
                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-figure text-error">
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="inline-block w-8 h-8 stroke-current"
                        fill="none"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                        >
                        </path>
                      </svg>
                    </div>
                    <div class="stat-title">Errors</div>
                    <div class="stat-value text-error">{@run.errors_count}</div>
                    <div class="stat-desc">Blocking issues</div>
                  </div>
                </div>

                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-figure text-warning">
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="inline-block w-8 h-8 stroke-current"
                        fill="none"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                        >
                        </path>
                      </svg>
                    </div>
                    <div class="stat-title">Warnings</div>
                    <div class="stat-value text-warning">{@run.warnings_count}</div>
                    <div class="stat-desc">Potential issues</div>
                  </div>
                </div>

                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-figure text-info">
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="inline-block w-8 h-8 stroke-current"
                        fill="none"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                        >
                        </path>
                      </svg>
                    </div>
                    <div class="stat-title">Info</div>
                    <div class="stat-value text-info">{@run.infos_count}</div>
                    <div class="stat-desc">Informational notices</div>
                  </div>
                </div>
              </div>

              <%!-- Notices List --%>
              <div class="mt-8 space-y-3">
                <%= for notice_group <- sorted_notices(@run.result_json["notices"] || []) do %>
                  <div class={[
                    "collapse collapse-arrow bg-base-100 border-l-4",
                    severity_border_class(notice_group["severity"])
                  ]}>
                    <input
                      type="checkbox"
                      checked={MapSet.member?(@expanded_codes, notice_group["code"])}
                      phx-click="toggle_notice"
                      phx-value-code={notice_group["code"]}
                    />
                    <div class="collapse-title pr-12">
                      <div class="flex items-center gap-3">
                        <.status_badge
                          status={notice_group["severity"]}
                          label={String.upcase(notice_group["severity"])}
                        />
                        <span class="font-mono text-sm font-medium">{notice_group["code"]}</span>
                      </div>
                      <div class="mt-1 text-sm text-base-content/70 flex items-center gap-2 flex-wrap">
                        <%= if filename = extract_filename(notice_group) do %>
                          <span class="font-medium text-base-content">{filename}</span>
                          <span>·</span>
                        <% end %>
                        <span>{format_count(get_total_notices(notice_group))} occurrences</span>
                        <%= if sample = extract_sample_context(notice_group) do %>
                          <span>·</span>
                          <span class="truncate max-w-md font-mono text-xs">{sample}</span>
                        <% end %>
                      </div>
                    </div>
                    <div class="collapse-content">
                      <div class="overflow-x-auto mt-2">
                        <table class="table table-zebra table-xs w-full">
                          <thead>
                            <tr>
                              <th>File</th>
                              <th>Line</th>
                              <th>Column</th>
                              <th>Message</th>
                            </tr>
                          </thead>
                          <tbody>
                            <%= for sample <- get_sample_notices(notice_group) do %>
                              <tr>
                                <td>{sample["filename"] || "-"}</td>
                                <td>{sample["csvRowNumber"] || "-"}</td>
                                <td>{sample["csvFieldName"] || "-"}</td>
                                <td class="whitespace-pre-wrap">{sample["message"] || "-"}</td>
                              </tr>
                            <% end %>
                          </tbody>
                        </table>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%= if Enum.empty?(@run.result_json["notices"] || []) do %>
                  <div class="text-center py-12 bg-base-100 rounded-lg border border-base-300">
                    <div class="text-success text-lg font-medium">
                      No validation issues found!
                    </div>
                    <p class="text-base-content/60 mt-2">Your GTFS data passed all checks.</p>
                  </div>
                <% end %>
              </div>
            <% true -> %>
              <%!-- Fallback State --%>
              <div class="hero min-h-[400px] bg-base-200 rounded-lg mt-6">
                <div class="hero-content text-center">
                  <div class="max-w-md">
                    <h1 class="text-3xl font-bold">Validation Results</h1>
                    <p class="py-6">Results not yet available.</p>
                  </div>
                </div>
              </div>
          <% end %>
        </Layouts.app>
      </div>
      <div class="drawer-side">
        <label for="validation-history-drawer" class="drawer-overlay"></label>
        <div class="menu p-4 w-96 min-h-full bg-base-200">
          <h2 class="text-xl font-bold mb-4">Validation History</h2>
          <div id="validation-runs-list" phx-update="stream" class="space-y-2">
            <div
              :for={{dom_id, run} <- @streams.validation_runs}
              id={dom_id}
              class="card bg-base-100 shadow-sm"
            >
              <div class="card-body p-4">
                <.link
                  navigate={~p"/gtfs/#{@current_gtfs_version.id}/validation/#{run.id}"}
                  class="block hover:bg-base-200 -m-4 p-4 rounded-lg transition-colors"
                >
                  <div class="flex items-center justify-between mb-2">
                    <div class="text-sm text-base-content/60">
                      {Calendar.strftime(run.started_at, "%Y-%m-%d %H:%M:%S")}
                    </div>
                    <.status_badge status={run.status} label={run.status} />
                  </div>
                  <%= if run.status == "completed" do %>
                    <div class="flex gap-4 text-xs">
                      <span class="text-error">E: {run.errors_count}</span>
                      <span class="text-warning">W: {run.warnings_count}</span>
                      <span class="text-info">I: {run.infos_count}</span>
                    </div>
                  <% end %>
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp sorted_notices(notices) do
    severity_order = %{
      "ERROR" => 0,
      "error" => 0,
      "WARNING" => 1,
      "warning" => 1,
      "INFO" => 2,
      "info" => 2
    }

    Enum.sort_by(notices, fn notice ->
      Map.get(severity_order, notice["severity"], 3)
    end)
  end

  defp get_sample_notices(notice_group) do
    notice_group
    |> Map.get("notices", [])
    |> List.first()
    |> case do
      nil -> []
      notice -> Map.get(notice, "sampleNotices", [])
    end
  end

  defp get_total_notices(notice_group) do
    notice_group
    |> Map.get("notices", [])
    |> List.first()
    |> case do
      nil -> 0
      notice -> Map.get(notice, "totalNotices", 0)
    end
  end

  defp extract_filename(notice_group) do
    notices = notice_group["notices"] || []
    sample_notices = List.first(notices)

    if sample_notices do
      sample_list = sample_notices["sampleNotices"] || []
      first_sample = List.first(sample_list)

      if first_sample && first_sample["filename"] do
        first_sample["filename"]
      else
        nil
      end
    else
      nil
    end
  end

  defp extract_sample_context(notice_group) do
    notices = notice_group["notices"] || []
    sample_notices = List.first(notices)

    if sample_notices do
      sample_list = sample_notices["sampleNotices"] || []

      # Extract up to 3 sample identifiers
      samples =
        sample_list
        |> Enum.take(3)
        |> Enum.map(fn sample ->
          cond do
            sample["stopId"] -> sample["stopId"]
            sample["routeId"] -> sample["routeId"]
            sample["stopName"] -> sample["stopName"]
            sample["fieldName"] -> sample["fieldName"]
            true -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      case samples do
        [] -> nil
        items -> Enum.join(items, ", ")
      end
    else
      nil
    end
  end

  defp format_count(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_count(count), do: to_string(count)

  defp format_pathways_overview_count(count) when is_integer(count), do: format_count(count)
  defp format_pathways_overview_count(_count), do: "0"

  defp format_pathways_overview_percentage(value) when is_number(value) do
    value
    |> normalize_pathways_numeric_value()
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_overview_percentage(_value), do: "0.0"

  attr :criteria_overview_rows, :list, default: []

  def pathways_criteria_comparison_section(assigns) do
    ~H"""
    <section
      id="pathways-criteria-comparison-overview"
      class="mt-8 rounded-xl border border-base-content/20 bg-base-100"
    >
      <div class="px-4 py-3 border-b border-base-content/15">
        <h3 class="text-sm font-semibold">Criteria Comparison Overview</h3>
      </div>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead class="text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th>Criterion</th>
              <th>Configured</th>
              <th>Evaluated</th>
              <th>Pass</th>
              <th>Fail</th>
              <th>N/A</th>
              <th>Pass Rate</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@criteria_overview_rows == []} id="pathways-criteria-comparison-empty">
              <td colspan="7" class="text-sm text-base-content/70">
                No criteria checks available.
              </td>
            </tr>

            <tr
              :for={criterion <- @criteria_overview_rows}
              id={"pathways-criteria-comparison-row-#{pathways_criteria_overview_kind(criterion)}"}
            >
              <th
                scope="row"
                id={"pathways-criteria-comparison-label-#{pathways_criteria_overview_kind(criterion)}"}
              >
                {Map.get(criterion, :label)}
              </th>
              <td
                id={
                  "pathways-criteria-comparison-configured-#{pathways_criteria_overview_kind(criterion)}"
                }
                class="font-mono tabular-nums"
              >
                {format_pathways_overview_count(Map.get(criterion, :configured_count, 0))}
              </td>
              <td
                id={
                  "pathways-criteria-comparison-evaluated-#{pathways_criteria_overview_kind(criterion)}"
                }
                class="font-mono tabular-nums"
              >
                {format_pathways_overview_count(Map.get(criterion, :evaluated_count, 0))}
              </td>
              <td
                id={"pathways-criteria-comparison-pass-#{pathways_criteria_overview_kind(criterion)}"}
                class="font-mono tabular-nums text-success"
              >
                {format_pathways_overview_count(Map.get(criterion, :pass_count, 0))}
              </td>
              <td
                id={"pathways-criteria-comparison-fail-#{pathways_criteria_overview_kind(criterion)}"}
                class="font-mono tabular-nums text-error"
              >
                {format_pathways_overview_count(Map.get(criterion, :fail_count, 0))}
              </td>
              <td
                id={
                  "pathways-criteria-comparison-not-evaluated-#{pathways_criteria_overview_kind(criterion)}"
                }
                class="font-mono tabular-nums"
              >
                {format_pathways_overview_count(Map.get(criterion, :not_evaluated_count, 0))}
              </td>
              <td
                id={"pathways-criteria-comparison-pass-rate-#{pathways_criteria_overview_kind(criterion)}"}
                class="font-mono tabular-nums"
              >
                {format_pathways_overview_percentage(Map.get(criterion, :pass_rate, 0.0))}%
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :trip_overview, :map, default: %{}

  def pathways_trip_visualization_overview_section(assigns) do
    ~H"""
    <section
      id="pathways-trip-visualization-overview"
      class="mt-8 rounded-xl border border-base-content/20 bg-base-100"
    >
      <div class="px-4 py-3 border-b border-base-content/15">
        <h3 class="text-sm font-semibold">Trip Reachability Summary</h3>
      </div>

      <div class="p-4">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3" id="pathways-trip-visualization-metrics">
          <div
            id="pathways-trip-overview-total-tests"
            class="rounded-lg border border-base-content/15 bg-base-100 px-4 py-3"
          >
            <div class="text-xs uppercase tracking-wide text-base-content/60">Total Tests</div>
            <div
              id="pathways-trip-overview-total-tests-value"
              class="mt-1 text-2xl font-semibold font-mono tabular-nums text-base-content"
            >
              {format_pathways_overview_count(Map.get(@trip_overview, :total_tests, 0))}
            </div>
          </div>

          <div
            id="pathways-trip-overview-pass-count"
            class="rounded-lg border border-base-content/15 bg-base-100 px-4 py-3"
          >
            <div class="text-xs uppercase tracking-wide text-base-content/60">Passed</div>
            <div
              id="pathways-trip-overview-pass-count-value"
              class="mt-1 text-2xl font-semibold font-mono tabular-nums text-success"
            >
              {format_pathways_overview_count(Map.get(@trip_overview, :pass_count, 0))}
            </div>
          </div>

          <div
            id="pathways-trip-overview-warning-count"
            class="rounded-lg border border-base-content/15 bg-base-100 px-4 py-3"
          >
            <div class="text-xs uppercase tracking-wide text-base-content/60">Warnings</div>
            <div
              id="pathways-trip-overview-warning-count-value"
              class="mt-1 text-2xl font-semibold font-mono tabular-nums text-warning"
            >
              {format_pathways_overview_count(Map.get(@trip_overview, :warning_count, 0))}
            </div>
          </div>

          <div
            id="pathways-trip-overview-fail-count"
            class="rounded-lg border border-base-content/15 bg-base-100 px-4 py-3"
          >
            <div class="text-xs uppercase tracking-wide text-base-content/60">Failed</div>
            <div
              id="pathways-trip-overview-fail-count-value"
              class="mt-1 text-2xl font-semibold font-mono tabular-nums text-error"
            >
              {format_pathways_overview_count(Map.get(@trip_overview, :fail_count, 0))}
            </div>
          </div>
        </div>

        <% duration_stats = Map.get(@trip_overview, :duration_seconds, %{}) %>
        <% distance_stats = Map.get(@trip_overview, :distance_meters, %{}) %>

        <div
          class="overflow-x-auto border border-base-content/15 bg-base-100 mt-4"
          id="pathways-trip-visualization-comparison"
        >
          <table class="table table-sm">
            <thead class="text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th>Metric</th>
                <th>Available</th>
                <th>Unavailable</th>
                <th>Availability</th>
                <th>Min</th>
                <th>Max</th>
                <th>Avg</th>
              </tr>
            </thead>
            <tbody>
              <tr id="pathways-trip-visualization-row-duration-seconds">
                <th scope="row">Duration (s)</th>
                <td id="pathways-trip-overview-duration-available" class="font-mono tabular-nums">
                  {format_pathways_overview_count(Map.get(duration_stats, :available_count, 0))}
                </td>
                <td id="pathways-trip-overview-duration-unavailable" class="font-mono tabular-nums">
                  {format_pathways_overview_count(Map.get(duration_stats, :unavailable_count, 0))}
                </td>
                <td
                  id="pathways-trip-overview-duration-availability-rate"
                  class="font-mono tabular-nums"
                >
                  {format_pathways_overview_percentage(
                    Map.get(duration_stats, :availability_rate, 0.0)
                  )}%
                </td>
                <td id="pathways-trip-overview-duration-min" class="font-mono tabular-nums">
                  {format_pathways_criteria_value(Map.get(duration_stats, :min))}
                </td>
                <td id="pathways-trip-overview-duration-max" class="font-mono tabular-nums">
                  {format_pathways_criteria_value(Map.get(duration_stats, :max))}
                </td>
                <td id="pathways-trip-overview-duration-average" class="font-mono tabular-nums">
                  {format_pathways_criteria_value(Map.get(duration_stats, :average))}
                </td>
              </tr>

              <tr id="pathways-trip-visualization-row-distance-meters">
                <th scope="row">Distance (m)</th>
                <td id="pathways-trip-overview-distance-available" class="font-mono tabular-nums">
                  {format_pathways_overview_count(Map.get(distance_stats, :available_count, 0))}
                </td>
                <td
                  id="pathways-trip-overview-distance-unavailable"
                  class="font-mono tabular-nums"
                >
                  {format_pathways_overview_count(Map.get(distance_stats, :unavailable_count, 0))}
                </td>
                <td
                  id="pathways-trip-overview-distance-availability-rate"
                  class="font-mono tabular-nums"
                >
                  {format_pathways_overview_percentage(
                    Map.get(distance_stats, :availability_rate, 0.0)
                  )}%
                </td>
                <td id="pathways-trip-overview-distance-min" class="font-mono tabular-nums">
                  {format_pathways_criteria_value(Map.get(distance_stats, :min))}
                </td>
                <td id="pathways-trip-overview-distance-max" class="font-mono tabular-nums">
                  {format_pathways_criteria_value(Map.get(distance_stats, :max))}
                </td>
                <td id="pathways-trip-overview-distance-average" class="font-mono tabular-nums">
                  {format_pathways_criteria_value(Map.get(distance_stats, :average))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          class="grid grid-cols-1 md:grid-cols-2 gap-3 mt-3"
          id="pathways-trip-visualization-strips"
        >
          <div
            class="rounded-lg border border-base-content/15 bg-base-100 p-3"
            id="pathways-trip-availability-strip-duration"
          >
            <div class="text-xs font-semibold mb-2">Duration data coverage</div>
            <progress
              id="pathways-trip-overview-duration-coverage-progress"
              class="progress progress-info w-full"
              value={Map.get(duration_stats, :availability_rate, 0.0)}
              max="100"
            >
            </progress>
            <div
              id="pathways-trip-overview-duration-coverage-value"
              class="text-xs mt-1 font-mono tabular-nums text-base-content/80"
            >
              {format_pathways_overview_percentage(Map.get(duration_stats, :availability_rate, 0.0))}%
            </div>
          </div>

          <div
            class="rounded-lg border border-base-content/15 bg-base-100 p-3"
            id="pathways-trip-availability-strip-distance"
          >
            <div class="text-xs font-semibold mb-2">Distance data coverage</div>
            <progress
              id="pathways-trip-overview-distance-coverage-progress"
              class="progress progress-success w-full"
              value={Map.get(distance_stats, :availability_rate, 0.0)}
              max="100"
            >
            </progress>
            <div
              id="pathways-trip-overview-distance-coverage-value"
              class="text-xs mt-1 font-mono tabular-nums text-base-content/80"
            >
              {format_pathways_overview_percentage(Map.get(distance_stats, :availability_rate, 0.0))}%
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp pathways_criteria_overview_kind(criterion) when is_map(criterion) do
    criterion
    |> Map.get(:kind, Map.get(criterion, "kind", "criterion"))
    |> to_string()
  end

  defp pathways_criteria_overview_kind(_criterion), do: "criterion"

  defp severity_border_class("error"), do: "border-error"
  defp severity_border_class("warning"), do: "border-warning"
  defp severity_border_class("info"), do: "border-info"
  defp severity_border_class(_), do: "border-base-300"

  defp pathways_case_display_status(row) do
    mismatch_map = pathways_mismatch_map(row.details_json)

    traversable_failed? =
      Map.has_key?(mismatch_map, "expected_traversable")

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

  defp pathways_case_issues(row) do
    case row.failure_category do
      "query_failure" -> [query_failure_issue(row.details_json)]
      "scoring_failure" -> scoring_failure_issue(row.details_json)
      _ -> ["All criteria passed"]
    end
  end

  defp query_failure_issue(details_json) when is_map(details_json) do
    reason = pathways_map_value(details_json, :reason)
    status = pathways_map_value(details_json, :status)

    case {reason, status} do
      {reason, status}
      when reason in ["non_2xx_response", :non_2xx_response] and is_integer(status) ->
        "Query failed: OTP returned HTTP #{status}"

      {reason, _status} when reason in ["timeout", :timeout] ->
        "Query failed: OTP request timed out"

      {nil, _status} ->
        "Query failed"

      {reason, _status} ->
        "Query failed: #{humanize_issue_token(reason)}"
    end
  end

  defp query_failure_issue(_details_json), do: "Query failed"

  defp scoring_failure_issue(details_json) when is_map(details_json) do
    details_json
    |> pathways_map_value(:mismatches)
    |> ensure_list()
    |> Enum.map(&mismatch_issue_reason/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> ["Criteria checks failed"]
      reasons -> reasons
    end
  end

  defp scoring_failure_issue(_details_json), do: ["Criteria checks failed"]

  defp mismatch_issue_reason(mismatch) do
    case mismatch_kind(mismatch) do
      "expected_traversable" -> "Traversability check failed"
      "expected_wheelchair_accessible" -> "Wheelchair accessibility check failed"
      "expected_min_duration_seconds" -> "Duration outside expected range"
      "expected_max_duration_seconds" -> "Duration outside expected range"
      "expected_min_distance_meters" -> "Distance outside expected range"
      "expected_max_distance_meters" -> "Distance outside expected range"
      nil -> nil
      kind -> "#{humanize_issue_token(kind)} failed"
    end
  end

  defp humanize_issue_token(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> humanize_issue_token()
  end

  defp humanize_issue_token(value) when is_binary(value) do
    value
    |> String.replace_prefix("expected_", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp map_has_entries?(map) when is_map(map), do: map_size(map) > 0
  defp map_has_entries?(_map), do: false

  defp pathways_case_origin(row) do
    row
    |> pathways_walkability_test_address()
    |> normalize_text()
  end

  defp pathways_case_destination(row) do
    row
    |> pathways_walkability_test_stop_id()
    |> normalize_text()
  end

  defp pathways_walkability_test_address(%{walkability_test: walkability_test})
       when is_struct(walkability_test) do
    walkability_test.address
  end

  defp pathways_walkability_test_address(_row), do: nil

  defp pathways_walkability_test_stop_id(%{walkability_test: walkability_test})
       when is_struct(walkability_test) do
    walkability_test.stop_id
  end

  defp pathways_walkability_test_stop_id(_row), do: nil

  defp format_pathways_time(nil), do: "-"

  defp format_pathways_time(%DateTime{} = value) do
    value
    |> DateTime.add(-5 * 60 * 60, :second)
    |> Calendar.strftime("%Y-%m-%d %I:%M:%S %p")
  end

  defp format_pathways_time(_value), do: "-"

  defp pathways_itinerary_step_rows(itinerary_steps_json) when is_map(itinerary_steps_json) do
    itinerary_steps_json
    |> pathways_map_value(:legs)
    |> ensure_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {leg, leg_position} ->
      leg_index = normalize_index(pathways_map_value(leg, :index), leg_position)
      leg_mode = normalize_text(pathways_map_value(leg, :mode))
      from_name = normalize_text(pathways_map_value(leg, :from_name))
      to_name = normalize_text(pathways_map_value(leg, :to_name))

      leg
      |> pathways_map_value(:steps)
      |> ensure_list()
      |> Enum.with_index()
      |> Enum.map(fn {step, step_position} ->
        %{
          leg_index: leg_index,
          step_index: normalize_index(pathways_map_value(step, :index), step_position),
          mode: leg_mode,
          street_name: normalize_text(pathways_map_value(step, :street_name)),
          relative_direction: normalize_text(pathways_map_value(step, :relative_direction)),
          absolute_direction: normalize_text(pathways_map_value(step, :absolute_direction)),
          distance_meters: normalize_distance(pathways_map_value(step, :distance_meters)),
          from_name: from_name,
          to_name: to_name
        }
      end)
    end)
  end

  defp pathways_itinerary_step_rows(_itinerary_steps_json), do: []

  defp pathways_map_value(map, key) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp pathways_map_value(_map, _key), do: nil

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_value), do: []

  defp normalize_index(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp normalize_index(_value, fallback), do: fallback

  defp normalize_text(value) when is_binary(value) and value != "", do: value
  defp normalize_text(_value), do: "-"

  defp normalize_distance(value) when is_float(value), do: value
  defp normalize_distance(value) when is_integer(value), do: value * 1.0
  defp normalize_distance(_value), do: nil

  defp format_pathways_distance(nil), do: "-"

  defp format_pathways_distance(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_distance(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pathways_distance(_value), do: "-"

  defp pathways_criteria_checks(row) do
    mismatch_map = pathways_mismatch_map(row.details_json)

    [
      criteria_check(
        row,
        mismatch_map,
        :expected_traversable,
        "Traversable",
        pathways_expected_value(row, :expected_traversable),
        row.route_exists
      ),
      duration_range_check(row, mismatch_map),
      distance_range_check(row, mismatch_map),
      criteria_check(
        row,
        mismatch_map,
        :expected_wheelchair_accessible,
        "Wheelchair accessible",
        pathways_expected_value(row, :expected_wheelchair_accessible),
        row.wheelchair_route_exists
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp pathways_case_criteria_checks(pathways_case_results) when is_list(pathways_case_results) do
    Enum.reduce(pathways_case_results, %{}, fn row, acc ->
      Map.put(acc, row.order_index, pathways_criteria_checks(row))
    end)
  end

  defp pathways_case_criteria_checks(_pathways_case_results), do: %{}

  defp pathways_criteria_overview(pathways_case_results) when is_list(pathways_case_results) do
    normalized_case_criteria = pathways_normalized_case_criteria(pathways_case_results)

    Enum.map(@pathways_criteria_overview_definitions, fn %{kind: kind, label: label} ->
      criteria_entries =
        Enum.map(normalized_case_criteria, fn per_case_criteria ->
          Map.get(per_case_criteria, kind, %{configured: false, status: :not_configured})
        end)

      configured_count = Enum.count(criteria_entries, & &1.configured)
      evaluated_count = Enum.count(criteria_entries, &pathways_evaluated_criterion?/1)
      pass_count = Enum.count(criteria_entries, &pathways_criterion_with_status?(&1, :pass))
      fail_count = Enum.count(criteria_entries, &pathways_criterion_with_status?(&1, :fail))

      not_evaluated_count =
        Enum.count(criteria_entries, &pathways_criterion_with_status?(&1, :not_evaluated))

      %{
        kind: kind,
        label: label,
        configured_count: configured_count,
        evaluated_count: evaluated_count,
        pass_count: pass_count,
        fail_count: fail_count,
        not_evaluated_count: not_evaluated_count,
        pass_rate: percentage(pass_count, evaluated_count)
      }
    end)
  end

  defp pathways_criteria_overview(_pathways_case_results), do: []

  defp pathways_normalized_case_criteria(pathways_case_results) do
    Enum.map(pathways_case_results, fn row ->
      row
      |> pathways_criteria_checks()
      |> Enum.reduce(%{}, fn check, acc ->
        Map.put(acc, check.kind, %{
          configured: true,
          status: check.status,
          expected: check.expected,
          actual: check.actual
        })
      end)
    end)
  end

  defp pathways_evaluated_criterion?(%{configured: true, status: status})
       when status in [:pass, :fail],
       do: true

  defp pathways_evaluated_criterion?(_criterion), do: false

  defp pathways_criterion_with_status?(%{configured: true, status: status}, status_to_match),
    do: status == status_to_match

  defp pathways_criterion_with_status?(_criterion, _status_to_match), do: false

  defp pathways_trip_overview(pathways_case_results) when is_list(pathways_case_results) do
    status_totals =
      Enum.reduce(pathways_case_results, %{pass: 0, warning: 0, failed: 0}, fn row, acc ->
        increment_pathways_trip_status(acc, pathways_case_display_status(row))
      end)

    total_tests = length(pathways_case_results)

    %{
      total_tests: total_tests,
      pass_count: status_totals.pass,
      warning_count: status_totals.warning,
      fail_count: status_totals.failed,
      duration_seconds:
        pathways_numeric_availability_stats(pathways_case_results, :duration_seconds),
      distance_meters:
        pathways_numeric_availability_stats(pathways_case_results, :distance_meters)
    }
  end

  defp pathways_trip_overview(_pathways_case_results) do
    %{
      total_tests: 0,
      pass_count: 0,
      warning_count: 0,
      fail_count: 0,
      duration_seconds: pathways_empty_numeric_availability_stats(),
      distance_meters: pathways_empty_numeric_availability_stats()
    }
  end

  defp increment_pathways_trip_status(acc, "pass"), do: Map.update!(acc, :pass, &(&1 + 1))
  defp increment_pathways_trip_status(acc, "warning"), do: Map.update!(acc, :warning, &(&1 + 1))
  defp increment_pathways_trip_status(acc, "failed"), do: Map.update!(acc, :failed, &(&1 + 1))
  defp increment_pathways_trip_status(acc, _status), do: acc

  defp pathways_numeric_availability_stats(pathways_case_results, field) do
    values =
      pathways_case_results
      |> Enum.map(&Map.get(&1, field))
      |> Enum.filter(&is_number/1)
      |> Enum.map(&normalize_pathways_numeric_value/1)

    total_count = length(pathways_case_results)
    available_count = length(values)
    unavailable_count = total_count - available_count

    summary =
      case values do
        [] ->
          pathways_empty_numeric_availability_stats()

        _ ->
          %{
            available_count: available_count,
            unavailable_count: unavailable_count,
            availability_rate: percentage(available_count, total_count),
            min: values |> Enum.min() |> Float.round(1),
            max: values |> Enum.max() |> Float.round(1),
            average: values |> Enum.sum() |> Kernel./(available_count) |> Float.round(1)
          }
      end

    summary
  end

  defp pathways_empty_numeric_availability_stats do
    %{
      available_count: 0,
      unavailable_count: 0,
      availability_rate: 0.0,
      min: nil,
      max: nil,
      average: nil
    }
  end

  defp normalize_pathways_numeric_value(value) when is_float(value), do: value
  defp normalize_pathways_numeric_value(value) when is_integer(value), do: value * 1.0

  defp percentage(_value, 0), do: 0.0

  defp percentage(value, total) do
    value
    |> Kernel.*(100)
    |> Kernel./(total)
    |> Float.round(1)
  end

  defp criteria_check(_row, _mismatch_map, _kind, _label, nil, _actual), do: nil

  defp criteria_check(row, mismatch_map, kind, label, expected, default_actual) do
    mismatch = Map.get(mismatch_map, Atom.to_string(kind))

    case {row.failure_category, mismatch} do
      {"query_failure", _} ->
        %{
          kind: Atom.to_string(kind),
          label: label,
          expected: expected,
          actual: default_actual,
          status: :not_evaluated
        }

      {_, nil} ->
        %{
          kind: Atom.to_string(kind),
          label: label,
          expected: expected,
          actual: default_actual,
          status: :pass
        }

      {_, mismatch} ->
        %{
          kind: Atom.to_string(kind),
          label: label,
          expected: pathways_map_value(mismatch, :expected),
          actual: pathways_map_value(mismatch, :actual),
          status: :fail
        }
    end
  end

  defp pathways_expected_value(%{walkability_test: walkability_test}, field)
       when is_struct(walkability_test) do
    Map.get(walkability_test, field)
  end

  defp pathways_expected_value(_row, _field), do: nil

  defp duration_range_check(row, mismatch_map) do
    min_duration = pathways_expected_value(row, :expected_min_duration_seconds)
    max_duration = pathways_expected_value(row, :expected_max_duration_seconds)

    if is_integer(min_duration) or is_integer(max_duration) do
      min_mismatch = Map.get(mismatch_map, "expected_min_duration_seconds")
      max_mismatch = Map.get(mismatch_map, "expected_max_duration_seconds")

      status = duration_range_status(row, min_mismatch, max_mismatch)

      %{
        kind: "duration_seconds_range",
        label: "Duration range (s)",
        expected: duration_range_expected_value(min_duration, max_duration),
        actual: duration_range_actual_value(row.duration_seconds, min_mismatch, max_mismatch),
        status: status
      }
    else
      nil
    end
  end

  defp duration_range_status(%{failure_category: "query_failure"}, _min_mismatch, _max_mismatch),
    do: :not_evaluated

  defp duration_range_status(_row, nil, nil), do: :pass
  defp duration_range_status(_row, _min_mismatch, _max_mismatch), do: :fail

  defp duration_range_expected_value(min_duration, max_duration)
       when is_integer(min_duration) and is_integer(max_duration) do
    "#{min_duration} - #{max_duration}"
  end

  defp duration_range_expected_value(min_duration, _max_duration) when is_integer(min_duration),
    do: ">= #{min_duration}"

  defp duration_range_expected_value(_min_duration, max_duration) when is_integer(max_duration),
    do: "<= #{max_duration}"

  defp duration_range_actual_value(default_actual, nil, nil), do: default_actual

  defp duration_range_actual_value(default_actual, min_mismatch, max_mismatch) do
    min_actual = mismatch_actual_value(min_mismatch)
    max_actual = mismatch_actual_value(max_mismatch)
    min_actual || max_actual || default_actual
  end

  defp mismatch_actual_value(nil), do: nil

  defp mismatch_actual_value(mismatch) when is_map(mismatch) do
    pathways_map_value(mismatch, :actual)
  end

  defp mismatch_actual_value(_mismatch), do: nil

  defp distance_range_check(row, mismatch_map) do
    min_distance = pathways_expected_value(row, :expected_min_distance_meters)
    max_distance = pathways_expected_value(row, :expected_max_distance_meters)

    if is_integer(min_distance) or is_integer(max_distance) do
      min_mismatch = Map.get(mismatch_map, "expected_min_distance_meters")
      max_mismatch = Map.get(mismatch_map, "expected_max_distance_meters")

      status = distance_range_status(row, min_mismatch, max_mismatch)

      %{
        kind: "distance_meters_range",
        label: "Distance range (m)",
        expected: distance_range_expected_value(min_distance, max_distance),
        actual: distance_range_actual_value(row.distance_meters, min_mismatch, max_mismatch),
        status: status
      }
    else
      nil
    end
  end

  defp distance_range_status(%{failure_category: "query_failure"}, _min_mismatch, _max_mismatch),
    do: :not_evaluated

  defp distance_range_status(_row, nil, nil), do: :pass
  defp distance_range_status(_row, _min_mismatch, _max_mismatch), do: :fail

  defp distance_range_expected_value(min_distance, max_distance)
       when is_integer(min_distance) and is_integer(max_distance) do
    "#{min_distance} - #{max_distance}"
  end

  defp distance_range_expected_value(min_distance, _max_distance) when is_integer(min_distance),
    do: ">= #{min_distance}"

  defp distance_range_expected_value(_min_distance, max_distance) when is_integer(max_distance),
    do: "<= #{max_distance}"

  defp distance_range_actual_value(default_actual, nil, nil), do: default_actual

  defp distance_range_actual_value(default_actual, min_mismatch, max_mismatch) do
    min_actual = mismatch_actual_value(min_mismatch)
    max_actual = mismatch_actual_value(max_mismatch)
    min_actual || max_actual || default_actual
  end

  defp pathways_mismatch_map(details_json) when is_map(details_json) do
    details_json
    |> pathways_map_value(:mismatches)
    |> ensure_list()
    |> Enum.reduce(%{}, fn mismatch, acc ->
      case mismatch_kind(mismatch) do
        nil -> acc
        kind -> Map.put(acc, kind, mismatch)
      end
    end)
  end

  defp pathways_mismatch_map(_details_json), do: %{}

  defp mismatch_kind(mismatch) when is_map(mismatch) do
    case pathways_map_value(mismatch, :kind) do
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind when is_binary(kind) -> kind
      _ -> nil
    end
  end

  defp mismatch_kind(_mismatch), do: nil

  defp format_pathways_criteria_value(nil), do: "-"
  defp format_pathways_criteria_value(value) when is_binary(value), do: value
  defp format_pathways_criteria_value(value) when is_boolean(value), do: to_string(value)
  defp format_pathways_criteria_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_pathways_criteria_value(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_criteria_value(value), do: inspect(value)

  defp pathways_criteria_status_label(:pass), do: "PASS"
  defp pathways_criteria_status_label(:fail), do: "FAIL"
  defp pathways_criteria_status_label(:not_evaluated), do: "N/A"

  defp pathways_criteria_status_icon(:pass), do: "hero-check-circle"
  defp pathways_criteria_status_icon(:fail), do: "hero-x-circle"
  defp pathways_criteria_status_icon(:not_evaluated), do: "hero-minus-circle"

  defp pathways_criteria_status_class(:pass), do: "text-success"
  defp pathways_criteria_status_class(:fail), do: "text-error"
  defp pathways_criteria_status_class(:not_evaluated), do: "text-base-content/70"

  defp pathways_empty_itinerary?(rows) when is_list(rows), do: rows == []
  defp pathways_empty_itinerary?(_rows), do: true

  defp pathways_empty_itinerary_text, do: "No itinerary steps available."

  defp maybe_schedule_pathways_status_poll(socket, %{
         run_type: "pathways_tests",
         status: status,
         id: id
       })
       when status in ["started", "running"] do
    schedule_pathways_status_poll(id)
    socket
  end

  defp maybe_schedule_pathways_status_poll(socket, _run), do: socket

  defp poll_current_pathways_run?(socket, validation_run_id) do
    case socket.assigns[:run] do
      %{id: ^validation_run_id, run_type: "pathways_tests", status: status}
      when status in ["started", "running"] ->
        true

      _ ->
        false
    end
  end

  defp schedule_pathways_status_poll(validation_run_id) do
    Process.send_after(
      self(),
      {:poll_pathways_trip_test_status, validation_run_id},
      @pathways_trip_test_poll_interval_ms
    )
  end

  defp refresh_pathways_run(socket, validation_run_id) do
    run = Validations.get_validation_run!(validation_run_id)
    {run, pathways_case_results} = load_pathways_render_data(run)
    pathways_failure = pathways_failure(run)
    pathways_failure_message = pathways_failure_message(run)

    socket
    |> assign(:run, run)
    |> assign(:pathways_preflight_issues, pathways_preflight_issues(run))
    |> assign(:pathways_failure, pathways_failure)
    |> assign(:pathways_failure_message, pathways_failure_message)
    |> assign(:pathways_failure_diagnostics, pathways_failure_diagnostics(run))
    |> assign(:pathways_case_results, pathways_case_results)
  end

  defp failure_summary(%{run_type: "pathways_tests"}, pathways_preflight_issues)
       when not is_nil(pathways_preflight_issues) do
    "Pathways export readiness failed before build packaging."
  end

  defp failure_summary(run, _pathways_preflight_issues), do: run.error_details

  defp pathways_preflight_issues(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        normalize_preflight_issues(payload)

      _other ->
        nil
    end
  end

  defp pathways_preflight_issues(_run), do: nil

  defp normalize_preflight_issues(payload) do
    details = payload_value(payload, :details)

    {blocking_errors, warnings} =
      case details do
        details when is_map(details) ->
          details_blocking_errors =
            details
            |> payload_value(:blocking_errors)
            |> normalize_preflight_issue_list()

          details_warnings =
            details
            |> payload_value(:warnings)
            |> normalize_preflight_issue_list()

          if details_blocking_errors == [] and details_warnings == [] do
            split_preflight_issues_by_severity(payload_value(payload, :issues))
          else
            {details_blocking_errors, details_warnings}
          end

        _other ->
          split_preflight_issues_by_severity(payload_value(payload, :issues))
      end

    if blocking_errors == [] and warnings == [] do
      nil
    else
      %{
        blocking_errors: blocking_errors,
        warnings: warnings
      }
    end
  end

  defp split_preflight_issues_by_severity(issues) do
    issues
    |> normalize_preflight_issue_list()
    |> Enum.split_with(&(&1.severity == :blocking))
  end

  defp normalize_preflight_issue_list(issues) when is_list(issues) do
    Enum.map(issues, &normalize_preflight_issue/1)
  end

  defp normalize_preflight_issue_list(_issues), do: []

  defp normalize_preflight_issue(issue) when is_map(issue) do
    code = payload_value(issue, :code)
    message = payload_value(issue, :message) || "Validation preparation issue"
    severity = normalize_preflight_issue_severity(payload_value(issue, :severity))

    context =
      payload_value(issue, :context) || payload_value(issue, :details) || %{}

    %{
      code: code,
      severity: severity,
      message: to_string(message),
      context: context
    }
  end

  defp normalize_preflight_issue(issue) do
    %{
      code: nil,
      severity: :blocking,
      message: inspect(issue),
      context: %{}
    }
  end

  defp normalize_preflight_issue_severity(value) when value in [:warning, "warning"], do: :warning
  defp normalize_preflight_issue_severity(_value), do: :blocking

  defp preflight_issue_context(issue) do
    context = Map.get(issue, :context, %{})

    [
      context_value(context, :file),
      context_value(context, :field),
      context_value(context, :stop_id),
      context_value(context, :pathway_id),
      context_value(context, :trip_id),
      context_value(context, :route_id),
      context_value(context, :service_id),
      context_value(context, :value)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      values -> Enum.join(values, " · ")
    end
  end

  defp context_value(context, key) when is_map(context) do
    case payload_value(context, key) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp pathways_failure_diagnostics(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        build_log_excerpt = pathways_failure_build_log_excerpt(payload)

        [
          presenter_detail("Exit status", pathways_failure_exit_status(payload)),
          presenter_detail("Build log path", pathways_failure_build_log_path(payload)),
          presenter_detail("Build log excerpt", build_log_excerpt),
          presenter_detail(
            "Likely GTFS source",
            pathways_failure_build_log_gtfs_source(build_log_excerpt)
          ),
          presenter_detail(
            "Likely cause",
            pathways_failure_npe_parent_station_hint(build_log_excerpt)
          )
        ]
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp pathways_failure_diagnostics(_run), do: []

  defp pathways_failure(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        payload
        |> ExportLive.classify_pathways_failure_category()
        |> ExportLive.present_pathways_failure(payload)

      _other ->
        nil
    end
  end

  defp pathways_failure(_run), do: nil

  defp pathways_failure_message(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        payload
        |> pathways_failure_tokens()
        |> Enum.find_value(&normalize_pathways_failure_code/1)
        |> case do
          nil -> failure_summary(%{error_details: error_details, run_type: "pathways_tests"}, nil)
          code -> Map.get(@pathways_failure_messages, code, "Pathways validation failed")
        end

      _other ->
        error_details
    end
  end

  defp pathways_failure_message(run), do: failure_summary(run, nil)

  defp pathways_failure_tokens(error_payload) do
    reason = payload_value(error_payload, :reason)

    details_reason =
      error_payload
      |> payload_value(:details)
      |> payload_value(:reason)

    issue_codes =
      error_payload
      |> payload_value(:issues)
      |> case do
        issues when is_list(issues) -> Enum.map(issues, &payload_value(&1, :code))
        _other -> []
      end

    [reason, details_reason | issue_codes]
  end

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
      "no_walkability_tests" -> :no_walkability_tests
      "otp_runtime_already_running" -> :otp_runtime_already_running
      "otp_start_failed" -> :otp_start_failed
      "otp_runtime_failed" -> :otp_runtime_failed
      "otp_ready_timeout" -> :otp_ready_timeout
      "otp_stop_failed" -> :otp_stop_failed
      "query_failure" -> :query_failure
      "scoring_failure" -> :scoring_failure
      "pathways_runner_spawn_failed" -> :pathways_runner_spawn_failed
      "pathways_trip_test_failed" -> :pathways_trip_test_failed
      "pathways_persistence_failed" -> :pathways_persistence_failed
      "pathways_export_prep_failed" -> :pathways_export_prep_failed
      "pathways_task_crashed" -> :pathways_task_crashed
      "pathways_status_unavailable" -> :pathways_status_unavailable
      "pathways_run_not_found" -> :pathways_run_not_found
      "pathways_invalid_run_type" -> :pathways_invalid_run_type
      "pathways_results_unavailable" -> :pathways_results_unavailable
      _other -> nil
    end
  end

  defp normalize_pathways_failure_code(_value), do: nil

  defp otp_data_requirements_summary, do: @otp_data_requirements_summary

  defp pathways_failure_exit_status(payload) do
    case pathways_build_failure_reason_code(payload) do
      :build_command_failed ->
        payload
        |> pathways_build_failure_details()
        |> payload_value(:exit_status)
        |> case do
          nil ->
            payload
            |> payload_value(:details)
            |> payload_value(:exit_status)

          exit_status ->
            exit_status
        end

      _other ->
        nil
    end
  end

  defp pathways_failure_build_log_path(payload) do
    case pathways_build_failure_reason_code(payload) do
      :build_command_failed ->
        payload
        |> pathways_build_failure_details()
        |> payload_value(:build_log_path)
        |> case do
          nil ->
            payload
            |> payload_value(:details)
            |> payload_value(:build_log_path)

          build_log_path ->
            build_log_path
        end

      _other ->
        nil
    end
  end

  defp pathways_failure_build_log_excerpt(payload) do
    case pathways_failure_build_log_path(payload) do
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
      nil -> nil
      filename -> "Issue appears to come from #{filename}."
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

  defp pathways_build_failure_reason_code(payload) do
    issue_reason_code =
      payload
      |> pathways_build_failure_details()
      |> payload_value(:reason_code)

    root_reason_code =
      payload
      |> payload_value(:details)
      |> payload_value(:reason_code)

    case issue_reason_code || root_reason_code do
      :build_command_failed -> :build_command_failed
      "build_command_failed" -> :build_command_failed
      _other -> nil
    end
  end

  defp pathways_build_failure_details(payload) do
    payload
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

  defp presenter_detail(_label, nil), do: nil
  defp presenter_detail(_label, ""), do: nil

  defp presenter_detail(label, value) do
    %{label: label, value: presenter_detail_value(value)}
  end

  defp presenter_detail_value(value) when is_binary(value), do: value
  defp presenter_detail_value(value) when is_atom(value), do: Atom.to_string(value)
  defp presenter_detail_value(value) when is_integer(value), do: Integer.to_string(value)
  defp presenter_detail_value(value), do: inspect(value)

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  defp load_pathways_render_data(%{run_type: "pathways_tests", status: "completed"} = run) do
    case Validations.get_pathways_trip_test_results(run.id) do
      {:ok, %{result_json: result_json, walkability_test_run_results: case_rows}} ->
        {%{run | result_json: result_json}, case_rows}

      {:error, _reason} ->
        {%{run | result_json: nil}, []}
    end
  end

  defp load_pathways_render_data(run), do: {run, []}

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

  defp validation_subtitle(%{run_type: "pathways_tests"}) do
    "Results of Open Trip Planner GTFS validation."
  end

  defp validation_subtitle(_run) do
    "Results of MobilityData GTFS validation."
  end
end
