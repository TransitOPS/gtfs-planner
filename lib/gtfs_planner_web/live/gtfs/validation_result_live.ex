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
              Results of MobilityData GTFS validation.
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
                        <th>Failure Category</th>
                        <th>Duration (s)</th>
                        <th>Distance (m)</th>
                        <th>Steps</th>
                        <th>Legs</th>
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
                            <span class={["badge badge-sm", case_status_badge_class(row.status)]}>
                              {String.upcase(to_string(row.status))}
                            </span>
                          </td>
                          <td>{row.failure_category || "-"}</td>
                          <td>{row.duration_seconds || "-"}</td>
                          <td>{format_pathways_distance(row.distance_meters)}</td>
                          <td>{row.step_count || "-"}</td>
                          <td>{row.leg_count || "-"}</td>
                          <td>{format_pathways_time(row.itinerary_start_time)}</td>
                          <td>{format_pathways_time(row.itinerary_end_time)}</td>
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

  defp case_status_badge_class("passed"), do: "badge-success"
  defp case_status_badge_class("failed"), do: "badge-error"
  defp case_status_badge_class(_), do: "badge-ghost"

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
    Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
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
end
