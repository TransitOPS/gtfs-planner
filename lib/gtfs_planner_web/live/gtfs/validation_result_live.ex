defmodule GtfsPlannerWeb.Gtfs.ValidationResultLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
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
      {:noreply,
       socket
       |> assign(:validation_id, validation_id)
       # Will be populated later
       |> assign(:result, nil)}
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
      <%!-- Pending version resolution hook (reused from ExportLive logic if needed, but typically router handles this before we get here for versionless) --%>
      <div class="flex items-center justify-center min-h-screen">
        <div class="text-center">
          <div class="loading loading-spinner loading-lg"></div>
          <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
        </div>
      </div>
    <% else %>
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
            <.link
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/export"}
              class="btn btn-outline btn-sm"
            >
              Back to Export
            </.link>
          </:actions>
        </.header>

        <%= if @result do %>
          <%!-- Summary Stats --%>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mt-6">
            <div class="stats shadow bg-base-100 border border-error/20">
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
                <div class="stat-value text-error">{@result.summary.errors}</div>
                <div class="stat-desc">Blocking issues</div>
              </div>
            </div>

            <div class="stats shadow bg-base-100 border border-warning/20">
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
                <div class="stat-value text-warning">{@result.summary.warnings}</div>
                <div class="stat-desc">Potential issues</div>
              </div>
            </div>

            <div class="stats shadow bg-base-100 border border-info/20">
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
                <div class="stat-value text-info">{@result.summary.infos}</div>
                <div class="stat-desc">Informational notices</div>
              </div>
            </div>
          </div>

          <%!-- Notices List --%>
          <div class="mt-8 space-y-4">
            <%= for notice_group <- @result.notices do %>
              <div class="collapse collapse-arrow bg-base-100 border border-base-300">
                <input
                  type="checkbox"
                  checked={MapSet.member?(@expanded_codes, notice_group.code)}
                  phx-click="toggle_notice"
                  phx-value-code={notice_group.code}
                />
                <div class="collapse-title text-lg font-medium flex items-center gap-4">
                  <div class={"badge badge-lg " <> severity_badge_class(notice_group.severity)}>
                    {String.upcase(notice_group.severity)}
                  </div>
                  <span class="font-mono text-sm opacity-70">{notice_group.code}</span>
                  <span class="flex-1"></span>
                  <span class="badge badge-neutral">{notice_group.total_notices}</span>
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
                        <%= for notice <- notice_group.notices do %>
                          <tr>
                            <td>{notice["filename"] || "-"}</td>
                            <td>{notice["csvRowNumber"] || "-"}</td>
                            <td>{notice["csvFieldName"] || "-"}</td>
                            <td class="whitespace-pre-wrap">{notice["message"] || "-"}</td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            <% end %>

            <%= if Enum.empty?(@result.notices) do %>
              <div class="text-center py-12 bg-base-100 rounded-lg border border-base-300">
                <div class="text-success text-lg font-medium">No validation issues found!</div>
                <p class="text-base-content/60 mt-2">Your GTFS data passed all checks.</p>
              </div>
            <% end %>
          </div>
        <% else %>
          <%!-- Placeholder state when result is nil (until Phase 2 implementation) --%>
          <div class="hero min-h-[400px] bg-base-200 rounded-lg mt-6">
            <div class="hero-content text-center">
              <div class="max-w-md">
                <h1 class="text-3xl font-bold">Validation Results</h1>
                <p class="py-6">Results for validation ID {@validation_id} will appear here.</p>
                <p class="text-sm opacity-60 italic">This is a placeholder for Phase 1B.</p>
              </div>
            </div>
          </div>
        <% end %>
      </Layouts.app>
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

  defp severity_badge_class("error"), do: "badge-error"
  defp severity_badge_class("warning"), do: "badge-warning"
  defp severity_badge_class("info"), do: "badge-info"
  defp severity_badge_class(_), do: "badge-ghost"
end
