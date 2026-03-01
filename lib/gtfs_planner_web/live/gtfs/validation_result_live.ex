defmodule GtfsPlannerWeb.Gtfs.ValidationResultLive do
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @pathways_trip_test_poll_interval_ms 250

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Validation Results")
     |> assign(:user_roles, user_roles)
     |> assign(:expanded_codes, MapSet.new())
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

      {:noreply,
       socket
       |> assign(:validation_id, validation_id)
       |> assign(:run, run)
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
            <div class={["badge badge-lg", status_badge_class(@run.status)]}>
              {String.upcase(@run.status)}
            </div>
          </div>

          <%= cond do %>
            <% @run.status == "failed" -> %>
              <%!-- Failed State --%>
              <div class="alert alert-error mt-6">
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
                  >
                  </path>
                </svg>
                <div>
                  <h3 class="font-bold">Validation Failed</h3>
                  <div class="text-sm mt-2">{@run.error_details}</div>
                </div>
              </div>
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
              <% summary = pathways_summary(@run) %>

              <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-6" id="pathways-result-summary">
                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-title">Total</div>
                    <div class="stat-value text-base-content">{summary.total}</div>
                  </div>
                </div>

                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-title">Passed</div>
                    <div class="stat-value text-success">{summary.passed}</div>
                  </div>
                </div>

                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-title">Failed</div>
                    <div class="stat-value text-error">{summary.failed}</div>
                  </div>
                </div>

                <div class="stats bg-base-100 border border-base-300">
                  <div class="stat">
                    <div class="stat-title">Pass Rate</div>
                    <div class="stat-value text-info">{summary.pass_rate}%</div>
                  </div>
                </div>
              </div>

              <%= if pathways_top_failure_categories(@run) != [] do %>
                <div class="mt-6" id="pathways-top-failure-categories">
                  <h3 class="text-sm font-semibold mb-2">Top Failure Categories</h3>
                  <ul class="space-y-1 text-sm">
                    <li :for={category <- pathways_top_failure_categories(@run)}>
                      {category["category"]}: {category["count"]}
                    </li>
                  </ul>
                </div>
              <% end %>

              <div class="mt-8" id="pathways-case-results">
                <h3 class="text-sm font-semibold mb-3">Per-Test Results</h3>
                <div class="overflow-x-auto">
                  <table class="table table-zebra table-sm">
                    <thead>
                      <tr>
                        <th>Order</th>
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
                    <tbody>
                      <%= for row <- @pathways_case_results do %>
                        <% itinerary_step_rows = pathways_itinerary_step_rows(row.itinerary_steps_json) %>

                        <tr id={"pathways-case-row-#{row.order_index}"}>
                          <td>{row.order_index}</td>
                          <td class="font-mono text-xs">{row.walkability_test_id}</td>
                          <td>
                            <span class={[
                              "badge badge-sm",
                              case_status_badge_class(pathways_case_display_status(row))
                            ]}>
                              {String.upcase(to_string(pathways_case_display_status(row)))}
                            </span>
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
                          <td colspan="10" class="p-0">
                            <details
                              id={"pathways-case-criteria-details-#{row.order_index}"}
                              class="border-t border-base-300"
                            >
                              <summary class="cursor-pointer px-3 py-2 text-xs font-semibold text-base-content/80">
                                Criteria checks
                              </summary>

                              <div class="px-3 pb-3">
                                <% criteria_checks = pathways_criteria_checks(row) %>

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
                          <td colspan="10" class="p-0">
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
                                          <th>From</th>
                                          <th>To</th>
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
                                          <td>{step.from_name}</td>
                                          <td>{step.to_name}</td>
                                        </tr>
                                      </tbody>
                                    </table>
                                  </div>
                                <% end %>
                              </div>
                            </details>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
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
                        <div class={[
                          "badge badge-sm font-semibold",
                          severity_badge_class(notice_group["severity"])
                        ]}>
                          {String.upcase(notice_group["severity"])}
                        </div>
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
                    <div class={["badge badge-sm", status_badge_class(run.status)]}>
                      {run.status}
                    </div>
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

  defp severity_badge_class("error"), do: "badge-error"
  defp severity_badge_class("warning"), do: "badge-warning"
  defp severity_badge_class("info"), do: "badge-info"
  defp severity_badge_class(_), do: "badge-ghost"

  defp severity_border_class("error"), do: "border-error"
  defp severity_border_class("warning"), do: "border-warning"
  defp severity_border_class("info"), do: "border-info"
  defp severity_border_class(_), do: "border-base-300"

  defp status_badge_class("started"), do: "badge-neutral"
  defp status_badge_class("running"), do: "badge-info"
  defp status_badge_class("completed"), do: "badge-success badge-outline"
  defp status_badge_class("failed"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"

  defp case_status_badge_class("pass"), do: "badge-success"
  defp case_status_badge_class("warning"), do: "badge-warning"
  defp case_status_badge_class("failed"), do: "badge-error"
  defp case_status_badge_class(_), do: "badge-ghost"

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
      {reason, status} when reason in ["non_2xx_response", :non_2xx_response] and is_integer(status) ->
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

  defp pathways_summary(run) do
    summary = Map.get(run.result_json || %{}, "summary", %{})

    %{
      total: Map.get(summary, "total", 0),
      passed: Map.get(summary, "passed", 0),
      failed: Map.get(summary, "failed", 0),
      pass_rate: Map.get(summary, "pass_rate", 0.0)
    }
  end

  defp pathways_top_failure_categories(run) do
    Map.get(run.result_json || %{}, "top_failure_categories", [])
  end

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

  defp criteria_check(_row, _mismatch_map, _kind, _label, nil, _actual), do: nil

  defp criteria_check(row, mismatch_map, kind, label, expected, default_actual) do
    mismatch = Map.get(mismatch_map, Atom.to_string(kind))

    case {row.failure_category, mismatch} do
      {"query_failure", _} ->
        %{kind: Atom.to_string(kind), label: label, expected: expected, actual: default_actual, status: :not_evaluated}

      {_, nil} ->
        %{kind: Atom.to_string(kind), label: label, expected: expected, actual: default_actual, status: :pass}

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

  defp pathways_expected_value(%{walkability_test: walkability_test}, field) when is_struct(walkability_test) do
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

    socket
    |> assign(:run, run)
    |> assign(:pathways_case_results, pathways_case_results)
  end

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
