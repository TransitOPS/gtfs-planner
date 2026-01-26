defmodule GtfsPlannerWeb.Gtfs.ExportLive do
  @moduledoc """
  LiveView for exporting GTFS data.
  Accessible by both pathways_studio_editor and pathways_studio_viewer roles.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # Check if version resolution is pending (versionless route)
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Export GTFS")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Export GTFS")
       |> assign(:user_roles, user_roles)
       |> assign(:export_type, :full)
       |> assign(:selected_validations, [])
       |> assign(:file_inventory, [])}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    # Skip if pending version resolution
    if socket.assigns[:pending_version_resolution] do
      {:noreply, socket}
    else
      # Load file inventory with real database counts
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      export_type = socket.assigns.export_type

      file_inventory =
        organization_id
        |> Gtfs.get_file_inventory(gtfs_version_id, export_type)
        |> Enum.sort_by(fn {filename, _count} -> filename end)

      {:noreply, assign(socket, :file_inventory, file_inventory)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    # Guard clause: if pending version resolution, we need to redirect to a version
    if socket.assigns[:pending_version_resolution] do
      current_organization = socket.assigns.current_organization

      # Use the version from localStorage if valid, otherwise fetch latest
      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          # Fetch latest version for the organization
          case Versions.get_latest_gtfs_version(current_organization.id) do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
          end
        end

      if version_to_use do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/export")}
      else
        # No versions available, stay on pending page
        {:noreply, socket}
      end
    else
      # Normal flow: we already have a current version
      current_organization = socket.assigns.current_organization
      current_version_id = to_string(socket.assigns.current_gtfs_version.id)

      # Try to use the stored version_id from localStorage
      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          # Fall back to latest version or current version
          case socket.assigns[:latest_gtfs_version] do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
            # Already on a valid route
            nil -> current_version_id
          end
        end

      # Only navigate if switching to a different version
      if version_to_use && version_to_use != current_version_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/export")}
      else
        # Already on correct version, do nothing
        {:noreply, socket}
      end
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
    validation_atom = String.to_atom(validation)
    current_validations = socket.assigns.selected_validations

    updated_validations =
      if validation_atom in current_validations do
        List.delete(current_validations, validation_atom)
      else
        [validation_atom | current_validations]
      end

    {:noreply, assign(socket, :selected_validations, updated_validations)}
  end

  @impl Phoenix.LiveView
  def handle_event("run_validation", _params, socket) do
    {:noreply, put_flash(socket, :info, "Validation functionality coming soon")}
  end

  @impl Phoenix.LiveView
  def handle_event("download_export", _params, socket) do
    {:noreply, put_flash(socket, :info, "Export functionality coming soon")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
      <%!-- Pending version resolution - mount the hook to trigger redirect --%>
      <div
        id="gtfs-version-resolver"
        phx-hook="GtfsVersionHook"
        data-organization-id={@current_organization.id}
      >
        <div class="flex items-center justify-center min-h-screen">
          <div class="text-center">
            <div class="loading loading-spinner loading-lg"></div>
            <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
          </div>
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

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mt-8">
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
            <button class="btn btn-primary mt-6 w-full" phx-click="download_export">
              Export GTFS
            </button>
          </div>

          <%!-- Validate Column --%>
          <div class="bg-base-100 rounded-lg p-6 border border-base-300">
            <h2 class="text-lg font-semibold mb-2">Validate</h2>
            <p class="text-sm text-base-content/70 mb-6">
              Run industry-standard validation checks to ensure data correctness before publishing. Includes MobilityData GTFS Validator and custom pathways trip tests.
            </p>

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
          </div>
        </div>
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
