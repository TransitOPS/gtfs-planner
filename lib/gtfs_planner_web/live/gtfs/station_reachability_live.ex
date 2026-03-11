defmodule GtfsPlannerWeb.Gtfs.StationReachabilityLive do
  @moduledoc """
  LiveView for station-level reachability validation.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationDiagramComponents

  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Otp.Lifecycle
  alias GtfsPlanner.Validations
  alias GtfsPlannerWeb.Gtfs.ExportLive
  alias LiveSelect.Component, as: LiveSelectComponent

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
     |> assign(:pathways_selection, default_pathways_selection())
     |> assign(:pathways_prep_detailed_progress, false)
     |> assign(:recent_validation_runs, [])
     |> assign(:station_walkability_tests, [])
     |> assign(:station_stop_labels, %{})
     |> assign(:platform_stop_ids, MapSet.new())
     |> assign(:show_walkability_drawer, false)
     |> assign(:walkability_stop, nil)
     |> assign(:walkability_form, to_form(default_walkability_form_params(), as: :walkability))
     |> assign(:walkability_selected_address, nil)
     |> assign(:walkability_selected_lat, nil)
     |> assign(:walkability_selected_lon, nil)
     |> assign(:walkability_selected_result, nil)
     |> assign(:walkability_last_results, [])
     |> assign(:walkability_error, nil)
     |> assign(:walkability_field_errors, %{})
     |> assign(:walkability_mode, :edit)
     |> assign(:editing_walkability_test, nil)}
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

        case station_scope_data(organization_id, gtfs_version_id, station) do
          {:ok, scope_data} ->
            {:noreply,
             socket
             |> assign(:stop_id, stop_id)
             |> assign(:station, station)
             |> assign(:recent_validation_runs, recent_validation_runs)
             |> assign(:station_walkability_tests, scope_data.station_walkability_tests)
             |> assign(:station_stop_labels, scope_data.station_stop_labels)
             |> assign(:platform_stop_ids, scope_data.platform_stop_ids)}

          {:error, :station_not_found} ->
            {:noreply,
             socket
             |> put_flash(:error, "Station not found")
             |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}
        end
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
                      <p
                        :if={issue.context_summary}
                        class="mt-1 font-mono text-xs text-base-content/70"
                      >
                        {issue.context_summary}
                      </p>
                    </li>
                  </ul>
                </section>
              <% end %>

              <%= if @pathways_failure do %>
                <section
                  id="station-pathways-failure-checks"
                  class="space-y-2 border-t border-base-300 pt-3"
                >
                  <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                    Recommended checks
                  </h4>
                  <ul class="list-disc space-y-1 pl-5 text-base-content/85">
                    <li :for={check <- @pathways_failure.checks}>{check}</li>
                  </ul>
                </section>
              <% end %>

              <%= if @pathways_failure_diagnostics != [] do %>
                <section
                  id="station-pathways-failure-diagnostics"
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
              <div
                class="rounded border border-base-200 px-3 py-2"
                id="reachability-summary-pass-rate"
              >
                <dt class="text-xs uppercase tracking-wide text-base-content/70">Pass rate</dt>
                <dd class="text-base font-semibold text-base-content">
                  {@validation_result.summary_cards.pass_rate}%
                </dd>
              </div>
            </dl>

            <div
              :if={@validation_result.top_failure_rows != []}
              id="station-reachability-top-failures"
            >
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

            <section
              id="station-reachability-coverage"
              class="space-y-3 rounded border border-base-200 p-3"
            >
              <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                Scope coverage
              </h4>

              <dl class="grid grid-cols-3 gap-2 text-sm">
                <div
                  id="station-reachability-coverage-in-scope"
                  class="rounded border border-base-200 px-3 py-2"
                >
                  <dt class="text-xs uppercase tracking-wide text-base-content/70">In scope</dt>
                  <dd class="text-base font-semibold text-base-content">
                    {@pathways_selection.in_scope_candidates}
                  </dd>
                </div>
                <div
                  id="station-reachability-coverage-selected"
                  class="rounded border border-base-200 px-3 py-2"
                >
                  <dt class="text-xs uppercase tracking-wide text-base-content/70">Selected</dt>
                  <dd class="text-base font-semibold text-base-content">
                    {@pathways_selection.selected_count}
                  </dd>
                </div>
                <div
                  id="station-reachability-coverage-invalid"
                  class="rounded border border-base-200 px-3 py-2"
                >
                  <dt class="text-xs uppercase tracking-wide text-base-content/70">Invalid</dt>
                  <dd class="text-base font-semibold text-base-content">
                    {@pathways_selection.invalid_count}
                  </dd>
                </div>
              </dl>

              <div
                :if={@pathways_selection.invalid_cases != []}
                id="station-reachability-invalid-cases"
                class="overflow-x-auto"
              >
                <table class="table table-xs">
                  <thead>
                    <tr>
                      <th>Test case</th>
                      <th>Reason</th>
                      <th>Stop</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={invalid_case <- @pathways_selection.invalid_cases}
                      id={"station-reachability-invalid-row-#{invalid_case.test_case_id}"}
                    >
                      <td class="font-mono text-xs">{invalid_case.test_case_id}</td>
                      <td>{invalid_case.reason_code}</td>
                      <td>{invalid_case.stop_id || "-"}</td>
                    </tr>
                  </tbody>
                </table>
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
                      <span class={[
                        "badge badge-sm",
                        case_status_badge_class(pathways_case_display_status(row))
                      ]}>
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

        <section id="station-reachability-test-cases" class="space-y-3 border-t border-base-200 pt-4">
          <h3 class="text-sm font-semibold text-base-content">Reachability test cases</h3>

          <%= if @station_walkability_tests == [] do %>
            <p class="px-4 py-3 text-sm text-base-content/60">
              No reachability test cases for this station.
            </p>
          <% else %>
            <div class="overflow-x-auto">
              <table id="station-walkability-tests-table" class="table table-sm">
                <thead>
                  <tr>
                    <th>Stop</th>
                    <th>Start address</th>
                    <th>Expected</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={test_case <- @station_walkability_tests}
                    id={"station-walkability-test-row-#{test_case.id}"}
                  >
                    <td>
                      <button
                        type="button"
                        id={"station-walkability-test-stop-#{test_case.id}"}
                        class="link link-primary"
                        phx-click="edit_walkability_test"
                        phx-value-id={test_case.id}
                      >
                        {Map.get(@station_stop_labels, test_case.stop_id, test_case.stop_id)}
                      </button>
                    </td>
                    <td class="max-w-80 truncate" title={test_case.address}>{test_case.address}</td>
                    <td>
                      <div class="space-y-0.5">
                        <p class="text-sm">
                          {if test_case.expected_traversable,
                            do: "Traversable",
                            else: "Not traversable"} / {if test_case.expected_wheelchair_accessible,
                            do: "Wheelchair",
                            else: "No wheelchair"}
                        </p>
                        <p
                          :if={present_text?(test_case.description)}
                          class="text-xs text-base-content/60 truncate"
                        >
                          {test_case.description}
                        </p>
                      </div>
                    </td>
                    <td class="tabular-nums text-sm">{format_timestamp(test_case.updated_at)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <.walkability_test_drawer
          open={@show_walkability_drawer}
          walkability_stop={@walkability_stop}
          walkability_form={@walkability_form}
          walkability_selected_address={@walkability_selected_address}
          walkability_selected_lat={@walkability_selected_lat}
          walkability_selected_lon={@walkability_selected_lon}
          walkability_error={@walkability_error}
          walkability_field_errors={@walkability_field_errors}
          walkability_mode={@walkability_mode}
          editing_walkability_test={@editing_walkability_test}
        />
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("edit_walkability_test", %{"id" => id}, socket) do
    case Validations.get_walkability_test(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      walkability_test ->
        case validate_walkability_test_scope(socket, walkability_test) do
          {:ok, stop} ->
            form_params = walkability_test_form_params(walkability_test)

            {:noreply,
             socket
             |> assign(:show_walkability_drawer, true)
             |> assign(:walkability_stop, stop)
             |> assign(:walkability_form, to_form(form_params, as: :walkability))
             |> assign(:walkability_selected_address, walkability_test.address)
             |> assign(:walkability_selected_lat, walkability_test.address_lat)
             |> assign(:walkability_selected_lon, walkability_test.address_lon)
             |> assign(:walkability_selected_result, nil)
             |> assign(:walkability_last_results, [])
             |> assign(:walkability_error, nil)
             |> assign(:walkability_field_errors, %{})
             |> assign(:walkability_mode, :edit)
             |> assign(:editing_walkability_test, walkability_test)}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  @impl true
  def handle_event("close_walkability_drawer", _params, socket) do
    {:noreply, reset_walkability_drawer(socket)}
  end

  @impl true
  def handle_event(
        "live_select_change",
        %{"text" => text, "id" => "walkability_address_autocomplete_component"},
        socket
      ) do
    case Geocoding.autocomplete(text) do
      {:ok, results} ->
        options =
          Enum.map(results, fn result ->
            %{
              label: result.formatted_address,
              value: result,
              option: result.formatted_address
            }
          end)

        send_update(LiveSelectComponent,
          id: "walkability_address_autocomplete_component",
          options: options
        )

        {:noreply, assign(socket, :walkability_last_results, results)}

      {:error, _reason} ->
        send_update(LiveSelectComponent,
          id: "walkability_address_autocomplete_component",
          options: []
        )

        {:noreply, assign(socket, :walkability_last_results, [])}
    end
  end

  @impl true
  def handle_event("live_select_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("live_select_blur", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("walkability_form_change", %{"walkability" => walkability_params}, socket) do
    current_params = socket.assigns.walkability_form.params || %{}
    merged_params = Map.merge(current_params, walkability_params)
    socket = assign(socket, :walkability_form, to_form(merged_params, as: :walkability))

    case Map.get(walkability_params, "address_autocomplete") do
      selection when is_binary(selection) and selection != "" ->
        {:noreply, apply_walkability_selection_from_form(socket, selection)}

      "" ->
        {:noreply, clear_walkability_selection(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("walkability_form_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_walkability_test", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    stop = socket.assigns.walkability_stop
    form_params = socket.assigns.walkability_form.params || %{}
    {address, address_lat, address_lon} = resolve_walkability_location(socket, form_params)

    cond do
      is_nil(stop) ->
        {:noreply,
         socket
         |> put_flash(:error, "Select a stop before saving.")
         |> assign(:walkability_error, "Select a stop before saving.")
         |> assign(:walkability_field_errors, %{})
         |> push_event("scroll_to_error", %{id: "walkability-error"})}

      is_nil(address) or is_nil(address_lat) or is_nil(address_lon) ->
        {:noreply,
         socket
         |> put_flash(:error, "Select an address from autocomplete.")
         |> assign(:walkability_error, "Select an address from autocomplete.")
         |> assign(:walkability_field_errors, %{})
         |> push_event("scroll_to_error", %{id: "walkability-error"})}

      true ->
        attrs = %{
          stop_id: stop.stop_id,
          address: address,
          address_lat: address_lat,
          address_lon: address_lon,
          description: form_params["description"],
          expected_traversable: form_params["expected_traversable"] == "true",
          expected_wheelchair_accessible: form_params["expected_wheelchair_accessible"] == "true",
          expected_min_duration_seconds:
            parse_optional_integer(form_params["expected_min_duration_seconds"]),
          expected_max_duration_seconds:
            parse_optional_integer(form_params["expected_max_duration_seconds"]),
          expected_min_distance_meters:
            parse_optional_integer(form_params["expected_min_distance_meters"]),
          expected_max_distance_meters:
            parse_optional_integer(form_params["expected_max_distance_meters"])
        }

        case socket.assigns.walkability_mode do
          :edit ->
            save_walkability_test_edit(socket, organization_id, attrs)

          :create ->
            save_walkability_test_create(socket, organization_id, attrs)
        end
    end
  end

  @impl true
  def handle_event("delete_walkability_test", %{"id" => id}, socket) do
    organization_id = socket.assigns.current_organization.id

    case Validations.get_walkability_test(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      walkability_test ->
        case validate_walkability_test_scope(socket, walkability_test) do
          {:ok, _stop} ->
            case Validations.delete_walkability_test(walkability_test) do
              {:ok, _deleted} ->
                purge_otp_artifact(organization_id, socket.assigns.current_gtfs_version.id)

                {:noreply,
                 socket
                 |> reset_walkability_drawer()
                 |> refresh_station_walkability_tests()}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Failed to delete walkability test.")}
            end

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
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

  defp resolve_walkability_location(socket, form_params) do
    selected_address = socket.assigns.walkability_selected_address
    selected_lat = socket.assigns.walkability_selected_lat
    selected_lon = socket.assigns.walkability_selected_lon
    form_address = Map.get(form_params, "address_autocomplete")

    cond do
      present_text?(selected_address) and present_coordinate?(selected_lat) and
          present_coordinate?(selected_lon) ->
        {selected_address, selected_lat, selected_lon}

      socket.assigns.walkability_mode == :edit and socket.assigns.editing_walkability_test != nil and
          (is_nil(form_address) or form_address == "" or
             form_address == socket.assigns.editing_walkability_test.address) ->
        {
          socket.assigns.editing_walkability_test.address,
          socket.assigns.editing_walkability_test.address_lat,
          socket.assigns.editing_walkability_test.address_lon
        }

      true ->
        {nil, nil, nil}
    end
  end

  @impl true
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
               |> assign(:pathways_selection, pathways_selection(pathways_results))
               |> assign(
                 :pathways_case_results,
                 Map.get(pathways_results, :walkability_test_run_results, [])
               )
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
           |> assign(:pathways_selection, default_pathways_selection())
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
           |> assign(:pathways_selection, default_pathways_selection())
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
    |> assign(:pathways_selection, default_pathways_selection())
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
    Enum.reduce(
      pathways_case_results,
      %{total_tests: 0, pass_count: 0, warning_count: 0, fail_count: 0},
      fn row, acc ->
        status = pathways_case_display_status(row)

        acc
        |> Map.update!(:total_tests, &(&1 + 1))
        |> increment_pathways_trip_status(status)
      end
    )
  end

  defp pathways_trip_overview(_pathways_case_results),
    do: %{total_tests: 0, pass_count: 0, warning_count: 0, fail_count: 0}

  defp increment_pathways_trip_status(acc, "pass"), do: Map.update!(acc, :pass_count, &(&1 + 1))

  defp increment_pathways_trip_status(acc, "warning"),
    do: Map.update!(acc, :warning_count, &(&1 + 1))

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
      presenter_detail(
        "Reason",
        Map.get(error_payload, :reason) || Map.get(error_payload, "reason")
      ),
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

  defp refresh_station_walkability_tests(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    case station_scope_data(organization_id, gtfs_version_id, station) do
      {:ok, scope_data} ->
        assign(socket,
          station_walkability_tests: scope_data.station_walkability_tests,
          station_stop_labels: scope_data.station_stop_labels,
          platform_stop_ids: scope_data.platform_stop_ids
        )

      {:error, :station_not_found} ->
        socket
        |> put_flash(:error, "Station not found")
        |> assign(:station_walkability_tests, [])
        |> assign(:station_stop_labels, %{})
        |> assign(:platform_stop_ids, MapSet.new())
    end
  end

  @spec station_scope_data(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok,
           %{
             station_walkability_tests: list(),
             station_stop_labels: map(),
             platform_stop_ids: MapSet.t()
           }}
          | {:error, :station_not_found}
  defp station_scope_data(organization_id, gtfs_version_id, station) do
    case Gtfs.list_station_scope_stop_ids(
           organization_id,
           gtfs_version_id,
           station.stop_id
         ) do
      {:ok, station_stop_ids} ->
        station_child_stops =
          Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)

        platform_stop_ids =
          station_child_stops
          |> Enum.filter(&(&1.location_type == 0 and &1.parent_station == station.stop_id))
          |> Enum.map(& &1.stop_id)
          |> MapSet.new()

        station_walkability_tests =
          Validations.list_walkability_tests_for_stop_ids(organization_id, station_stop_ids)

        station_stop_labels =
          station_child_stops
          |> Enum.reduce(
            %{station.stop_id => station.stop_name || station.stop_id},
            fn child_stop, labels ->
              Map.put(labels, child_stop.stop_id, child_stop.stop_name || child_stop.stop_id)
            end
          )

        {:ok,
         %{
           station_walkability_tests: station_walkability_tests,
           station_stop_labels: station_stop_labels,
           platform_stop_ids: platform_stop_ids
         }}

      {:error, :station_not_found} ->
        {:error, :station_not_found}
    end
  end

  defp save_walkability_test_create(socket, organization_id, attrs) do
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Validations.create_walkability_test(organization_id, gtfs_version_id, attrs) do
      {:ok, _walkability_test} ->
        purge_otp_artifact(organization_id, gtfs_version_id)

        {:noreply,
         socket
         |> reset_walkability_drawer()
         |> refresh_station_walkability_tests()}

      {:error, changeset} ->
        error_message =
          if duplicate_walkability_test?(changeset) do
            "This address is already registered for this stop."
          else
            "Failed to create test case."
          end

        field_errors = extract_field_errors(changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_message)
         |> assign(:walkability_error, error_message)
         |> assign(:walkability_field_errors, field_errors)
         |> push_event("scroll_to_error", %{id: "walkability-error"})}
    end
  end

  defp save_walkability_test_edit(socket, organization_id, attrs) do
    editing_walkability_test = socket.assigns.editing_walkability_test

    cond do
      is_nil(editing_walkability_test) ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      true ->
        case Validations.get_walkability_test(editing_walkability_test.id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Walkability test not found.")}

          walkability_test when walkability_test.organization_id != organization_id ->
            {:noreply, put_flash(socket, :error, "Unauthorized walkability test access.")}

          walkability_test ->
            case validate_walkability_test_scope(socket, walkability_test) do
              {:ok, _stop} ->
                case Validations.update_walkability_test(walkability_test, attrs) do
                  {:ok, _updated_walkability_test} ->
                    purge_otp_artifact(organization_id, socket.assigns.current_gtfs_version.id)

                    {:noreply,
                     socket
                     |> reset_walkability_drawer()
                     |> refresh_station_walkability_tests()
                     |> put_flash(:info, "Walkability test updated.")}

                  {:error, changeset} ->
                    error_message =
                      if duplicate_walkability_test?(changeset) do
                        "This address is already registered for this stop."
                      else
                        "Failed to update test case."
                      end

                    field_errors = extract_field_errors(changeset)

                    {:noreply,
                     socket
                     |> put_flash(:error, error_message)
                     |> assign(:walkability_error, error_message)
                     |> assign(:walkability_field_errors, field_errors)
                     |> push_event("scroll_to_error", %{id: "walkability-error"})}
                end

              {:error, message} ->
                {:noreply, put_flash(socket, :error, message)}
            end
        end
    end
  end

  defp validate_walkability_test_scope(socket, walkability_test) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    stop = Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, walkability_test.stop_id)

    cond do
      walkability_test.organization_id != organization_id ->
        {:error, "Unauthorized walkability test access."}

      is_nil(stop) ->
        {:error, "Walkability test stop not found."}

      not stop_belongs_to_station?(
        stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) ->
        {:error, "Unauthorized walkability test access."}

      true ->
        {:ok, stop}
    end
  end

  defp stop_belongs_to_station?(stop, station_stop_id, platform_stop_ids) do
    stop.parent_station == station_stop_id or
      MapSet.member?(platform_stop_ids, stop.parent_station)
  end

  defp reset_walkability_drawer(socket) do
    socket
    |> assign(:show_walkability_drawer, false)
    |> assign(:walkability_stop, nil)
    |> assign(:walkability_form, to_form(default_walkability_form_params(), as: :walkability))
    |> clear_walkability_selection()
    |> assign(:walkability_last_results, [])
    |> assign(:walkability_error, nil)
    |> assign(:walkability_field_errors, %{})
    |> assign(:walkability_mode, :edit)
    |> assign(:editing_walkability_test, nil)
  end

  defp default_walkability_form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "address_autocomplete" => "",
        "description" => "",
        "expected_traversable" => false,
        "expected_wheelchair_accessible" => false,
        "expected_min_duration_seconds" => "",
        "expected_max_duration_seconds" => "",
        "expected_min_distance_meters" => "",
        "expected_max_distance_meters" => ""
      },
      overrides
    )
  end

  defp walkability_test_form_params(walkability_test) do
    default_walkability_form_params(%{
      "address_autocomplete" => walkability_test.address,
      "description" => walkability_test.description || "",
      "expected_traversable" => walkability_test.expected_traversable || false,
      "expected_wheelchair_accessible" =>
        walkability_test.expected_wheelchair_accessible || false,
      "expected_min_duration_seconds" =>
        to_optional_string(walkability_test.expected_min_duration_seconds),
      "expected_max_duration_seconds" =>
        to_optional_string(walkability_test.expected_max_duration_seconds),
      "expected_min_distance_meters" =>
        to_optional_string(walkability_test.expected_min_distance_meters),
      "expected_max_distance_meters" =>
        to_optional_string(walkability_test.expected_max_distance_meters)
    })
  end

  defp clear_walkability_selection(socket) do
    current_params = socket.assigns.walkability_form.params || %{}
    preserved = Map.drop(current_params, ["address_autocomplete"])
    updated_params = default_walkability_form_params(preserved)

    socket
    |> assign(:walkability_form, to_form(updated_params, as: :walkability))
    |> assign(:walkability_selected_address, nil)
    |> assign(:walkability_selected_lat, nil)
    |> assign(:walkability_selected_lon, nil)
    |> assign(:walkability_selected_result, nil)
  end

  defp apply_walkability_selection(socket, result) do
    current_params = socket.assigns.walkability_form.params || %{}

    updated_params =
      default_walkability_form_params(
        Map.merge(current_params, %{"address_autocomplete" => result.formatted_address})
      )

    socket
    |> assign(:walkability_form, to_form(updated_params, as: :walkability))
    |> assign(:walkability_selected_address, result.formatted_address)
    |> assign(:walkability_selected_lat, result.lat)
    |> assign(:walkability_selected_lon, result.lon)
    |> assign(:walkability_selected_result, result)
  end

  defp normalize_geocoding_result(%Geocoding.Result{} = result), do: {:ok, result}

  defp normalize_geocoding_result(%{} = result) do
    with formatted_address when is_binary(formatted_address) <-
           Map.get(result, "formatted_address"),
         lat when is_float(lat) <- Map.get(result, "lat"),
         lon when is_float(lon) <- Map.get(result, "lon") do
      {:ok,
       %Geocoding.Result{
         formatted_address: formatted_address,
         lat: lat,
         lon: lon,
         city: Map.get(result, "city"),
         state: Map.get(result, "state"),
         country: Map.get(result, "country")
       }}
    else
      _ -> :error
    end
  end

  defp normalize_geocoding_result(_result), do: :error

  defp apply_walkability_selection_from_form(socket, selection) do
    with {:ok, decoded_selection} <- decode_live_select_selection(selection),
         {:ok, result} <- normalize_geocoding_result(decoded_selection) do
      apply_walkability_selection(socket, result)
    else
      _ ->
        socket.assigns.walkability_last_results
        |> Enum.find(fn result -> result.formatted_address == selection end)
        |> case do
          nil -> clear_walkability_selection(socket)
          result -> apply_walkability_selection(socket, result)
        end
    end
  end

  defp decode_live_select_selection(selection) when is_binary(selection) do
    {:ok, LiveSelect.decode(selection)}
  rescue
    _ -> :error
  end

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> nil
    end
  end

  defp parse_optional_integer(_value), do: nil

  defp to_optional_string(nil), do: ""
  defp to_optional_string(value), do: to_string(value)

  defp extract_field_errors(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.group_by(fn {field, _error} -> field end, fn {_field, {msg, opts}} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp duplicate_walkability_test?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] in [
            "walkability_tests_organization_id_stop_id_address_index",
            "walkability_tests_organization_id_gtfs_version_id_stop_id_address_index"
          ]

      _ ->
        false
    end)
  end

  defp purge_otp_artifact(organization_id, gtfs_version_id) do
    case Lifecycle.purge_artifact_on_success(organization_id, gtfs_version_id) do
      {:ok, :purged} -> :ok
      {:ok, :not_found} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp format_timestamp(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  defp format_timestamp(_value), do: "—"

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp present_coordinate?(value) when is_integer(value), do: true
  defp present_coordinate?(value) when is_float(value), do: true
  defp present_coordinate?(%Decimal{}), do: true
  defp present_coordinate?(_value), do: false

  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")

  defp pathways_prep_status_callback(live_view_pid) do
    fn payload ->
      send(live_view_pid, {:pathways_prep_progress, payload})
    end
  end

  defp pathways_status_progress("started"),
    do: %{phase: {:pathways_prep, :cache_check}, percent: 10}

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

  defp pathways_selection(pathways_results) do
    pathways_results
    |> Map.get(:result_json, %{})
    |> Map.get("selection")
    |> normalize_pathways_selection()
  end

  defp default_pathways_selection do
    %{
      total_candidates: 0,
      in_scope_candidates: 0,
      selected_count: 0,
      invalid_count: 0,
      selected_test_case_ids: [],
      invalid_test_case_ids: [],
      invalid_cases: []
    }
  end

  defp normalize_pathways_selection(selection) when is_map(selection) do
    %{
      total_candidates: non_negative_integer(selection["total_candidates"]),
      in_scope_candidates: non_negative_integer(selection["in_scope_candidates"]),
      selected_count: non_negative_integer(selection["selected_count"]),
      invalid_count: non_negative_integer(selection["invalid_count"]),
      selected_test_case_ids: list_or_empty(selection["selected_test_case_ids"]),
      invalid_test_case_ids: list_or_empty(selection["invalid_test_case_ids"]),
      invalid_cases:
        selection["invalid_cases"]
        |> list_or_empty()
        |> Enum.map(&normalize_invalid_case/1)
    }
  end

  defp normalize_pathways_selection(_selection), do: default_pathways_selection()

  defp normalize_invalid_case(invalid_case) when is_map(invalid_case) do
    %{
      test_case_id:
        invalid_case["test_case_id"] || invalid_case["walkability_test_id"] || "unknown",
      reason_code: invalid_case["reason_code"] || "unknown",
      stop_id: invalid_case["stop_id"]
    }
  end

  defp normalize_invalid_case(_invalid_case) do
    %{
      test_case_id: "unknown",
      reason_code: "unknown",
      stop_id: nil
    }
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []
end
