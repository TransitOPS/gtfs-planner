defmodule GtfsPlannerWeb.Gtfs.ValidationResultLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Validation Results")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Validation Results")
       |> assign(:user_roles, user_roles)
       |> assign(:expanded_codes, MapSet.new())}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(%{"validation_id" => validation_id}, _uri, socket) do
    if socket.assigns[:pending_version_resolution] do
      {:noreply, socket}
    else
      run = Validations.get_validation_run!(validation_id)
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      validation_runs_history = Validations.list_validation_runs(organization_id, gtfs_version_id)

      {:noreply,
       socket
       |> assign(:validation_id, validation_id)
       |> assign(:run, run)
       |> stream(:validation_runs, validation_runs_history)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    if socket.assigns[:pending_version_resolution] do
      current_organization = socket.assigns.current_organization

      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          case Versions.get_latest_gtfs_version(current_organization.id) do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
          end
        end

      if version_to_use do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/export")}
      else
        {:noreply, socket}
      end
    else
      current_organization = socket.assigns.current_organization
      current_version_id = to_string(socket.assigns.current_gtfs_version.id)

      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          case socket.assigns[:latest_gtfs_version] do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
            nil -> current_version_id
          end
        end

      if version_to_use && version_to_use != current_version_id do
        validation_id = socket.assigns[:validation_id]

        if validation_id do
          {:noreply,
           push_navigate(socket, to: "/gtfs/#{version_to_use}/validation/#{validation_id}")}
        else
          {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/export")}
        end
      else
        {:noreply, socket}
      end
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
    <%= if assigns[:pending_version_resolution] do %>
      <%!-- Pending version resolution hook --%>
      <div class="flex items-center justify-center min-h-screen">
        <div class="text-center">
          <div class="loading loading-spinner loading-lg"></div>
          <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
        </div>
      </div>
    <% else %>
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
              <% @run.status == "completed" and @run.result_json -> %>
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
    <% end %>
    """
  end

  defp get_user_roles(socket) do
    user = socket.assigns[:current_user]
    organization = socket.assigns[:current_organization]

    case GtfsPlanner.Accounts.get_user_org_membership(user.id, organization.id) do
      %UserOrgMembership{roles: roles} when is_list(roles) -> roles
      _ -> []
    end
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
